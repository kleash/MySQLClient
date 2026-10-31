import XCTest
@testable import MySQLMacClient

/// Runs against the `TestDatabase` server, in a scratch database of its own.
/// Every test checks what the server holds afterwards, not just what the
/// view model reports.
@MainActor
final class DatabaseRestoreViewModelTests: XCTestCase {
    private let database = "mysqlmacclient_restore"
    private let other = "mysqlmacclient_restore_other"
    private var service: MySQLService!
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sql")
        service = MySQLService()
        try await service.connect(
            host: TestDatabase.host,
            port: TestDatabase.port,
            username: TestDatabase.username,
            password: TestDatabase.password,
            database: nil
        )
        _ = try await service.rawQuery("DROP DATABASE IF EXISTS `\(database)`")
        _ = try await service.rawQuery("DROP DATABASE IF EXISTS `\(other)`")
        _ = try await service.rawQuery("CREATE DATABASE `\(database)`")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL)
        guard let service else { return }
        _ = try? await service.rawQuery("DROP DATABASE IF EXISTS `\(database)`")
        _ = try? await service.rawQuery("DROP DATABASE IF EXISTS `\(other)`")
        try await service.disconnect()
    }

    private func restore(_ contents: Data, configure: (DatabaseRestoreViewModel) -> Void = { _ in }) async throws -> DatabaseRestoreViewModel {
        try contents.write(to: fileURL)
        let viewModel = DatabaseRestoreViewModel(service: service, database: DatabaseInfo(name: database))
        viewModel.inputFileURL = fileURL
        configure(viewModel)
        viewModel.startRestore()
        while viewModel.isRunning { await Task.yield() }
        return viewModel
    }

    private func ids(in table: String) async throws -> [Int] {
        try await service.query("SELECT id FROM `\(database)`.`\(table)` ORDER BY id").compactMap { $0.column("id")?.int }
    }

    func testStopsAtTheFirstFailedStatementAndSaysWhere() async throws {
        let viewModel = try await restore(Data("""
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (2);
            """.utf8))

        XCTAssertEqual(viewModel.failure, .stoppedAtError(line: 3))
        XCTAssertEqual(viewModel.statementErrors.map(\.line), [3])
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1], "nothing after the failed statement may run")
    }

    func testCarriesOnPastFailedStatementsWhenAsked() async throws {
        let viewModel = try await restore(Data("""
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (2);
            """.utf8)) { $0.stopOnFirstError = false }

        XCTAssertEqual(viewModel.statementErrors.map(\.line), [3])
        XCTAssertNil(viewModel.failure)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1, 2])
    }

    /// A lenient decode would store U+FFFD in place of these bytes.
    func testRefusesAStatementThatIsNotUTF8InsteadOfAlteringIt() async throws {
        var contents = Data("CREATE TABLE t (id INT PRIMARY KEY, b BLOB);\nINSERT INTO t VALUES (1, '".utf8)
        contents.append(contentsOf: [0xFF, 0xFE, 0x00, 0xC3])
        contents.append(Data("');\nINSERT INTO t VALUES (2, 'ok');\n".utf8))
        let viewModel = try await restore(contents)

        XCTAssertEqual(viewModel.failure, .notUTF8(line: 2))
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [])
    }

    /// Restoring into a chosen database, the file can't switch away from
    /// it, create or drop the database it was made from.
    func testSkipsTheFilesOwnDatabaseStatementsWhenRestoringIntoAnother() async throws {
        let script = """
            /*!40000 DROP DATABASE IF EXISTS `\(other)`*/;
            DROP DATABASE IF EXISTS `\(other)`;
            CREATE DATABASE IF NOT EXISTS `\(other)`;
            use `\(other)`;
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (7);
            """
        let viewModel = try await restore(Data(script.utf8))

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.didFinishSuccessfully)
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [7])
        let others = try await service.query("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '\(other)'")
        XCTAssertTrue(others.isEmpty, "the file's own database must not be created")
    }

    /// mysqldump changes its database's collation around a routine made
    /// under another one; restored elsewhere, the original keeps its own.
    func testLeavesTheOriginalDatabasesCollationAloneWhenRestoringIntoAnother() async throws {
        _ = try await service.rawQuery("CREATE DATABASE `\(other)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        let viewModel = try await restore(Data("""
            ALTER DATABASE `\(other)` CHARACTER SET latin1 COLLATE latin1_swedish_ci ;
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (1);
            ALTER DATABASE `\(other)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci ;
            """.utf8))

        // Stopped between the two: the original must not be left changed.
        XCTAssertEqual(viewModel.failure, .stoppedAtError(line: 4))
        let collation = try await service.query("SELECT DEFAULT_COLLATION_NAME AS c FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '\(other)'")
        XCTAssertEqual(collation.first?.column("c")?.string, "utf8mb4_unicode_ci")
    }

    func testFollowsTheFilesOwnDatabaseWhenAsked() async throws {
        let viewModel = try await restore(Data("""
            CREATE DATABASE IF NOT EXISTS `\(other)`;
            USE `\(other)`;
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (7);
            """.utf8)) { $0.useDatabaseNamedInFile = true }

        XCTAssertNil(viewModel.errorMessage)
        let restored = try await service.query("SELECT id FROM `\(other)`.t").compactMap { $0.column("id")?.int }
        XCTAssertEqual(restored, [7])
        let inTarget = try await service.query("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '\(database)'")
        XCTAssertTrue(inTarget.isEmpty)
    }

    func testRecognisesTheStatementsThatChooseADatabase() {
        for statement in ["USE `x`", "use x", "CREATE DATABASE x", "create schema if not exists x",
                          "DROP DATABASE IF EXISTS x", "/*!40000 DROP DATABASE IF EXISTS `x`*/", "CREATE DATABASE /*!32312 IF NOT EXISTS*/ `x`",
                          "ALTER DATABASE `x` CHARACTER SET latin1 COLLATE latin1_swedish_ci ;"] {
            XCTAssertTrue(DatabaseRestoreViewModel.choosesDatabase(statement), statement)
        }
        for statement in ["USER_LOCK()", "UPDATE t SET a = 1", "CREATE TABLE databases (id INT)", "SELECT 'USE x'", "/*!40101 SET NAMES utf8mb4 */",
                          "ALTER TABLE databases ADD c INT"] {
            XCTAssertFalse(DatabaseRestoreViewModel.choosesDatabase(statement), statement)
        }
    }

    /// The server drops the restore's connection part-way. It must stop
    /// there, and say where, rather than reconnect and run the rest of the
    /// file in a new session without the file's USE and settings.
    func testStopsWhenItsConnectionDropsAndRunsNothingAfterwards() async throws {
        var lines = ["CREATE TABLE t (id INT PRIMARY KEY);"]
        for id in 1...20 {
            lines.append("INSERT INTO t VALUES (\(id));")
            lines.append("SELECT SLEEP(0.05);")
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: fileURL)
        let viewModel = DatabaseRestoreViewModel(service: service, database: DatabaseInfo(name: database))
        viewModel.inputFileURL = fileURL
        viewModel.startRestore()

        try await Task.sleep(for: .milliseconds(400))
        let restoreConnection = try await service.query("""
            SELECT ID AS id FROM information_schema.PROCESSLIST WHERE DB = '\(database)' AND ID <> CONNECTION_ID()
            """).first?.column("id")?.int
        try await service.execute("KILL \(try XCTUnwrap(restoreConnection))")
        while viewModel.isRunning { await Task.yield() }

        guard case .connectionLost(let line)? = viewModel.failure else {
            return XCTFail("expected the connection-lost error, got \(viewModel.errorMessage ?? "nil")")
        }
        // Line 2i holds INSERT i: exactly the inserts before the failing
        // line ran, each once.
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, Array(stride(from: 1, through: (line - 1) / 2, by: 1)))
        XCTAssertLessThan(restored.count, 20)
    }
}
