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

    private func restore(_ contents: Data, using connection: MySQLService? = nil,
                         configure: (DatabaseRestoreViewModel) -> Void = { _ in }) async throws -> DatabaseRestoreViewModel {
        try contents.write(to: fileURL)
        let viewModel = DatabaseRestoreViewModel(service: connection ?? service, database: DatabaseInfo(name: database))
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

    /// Routines made under NO_BACKSLASH_ESCAPES, as mysqldump, HeidiSQL and
    /// this app's backup write them: after the file's SET sql_mode, `'C:\'`
    /// is a whole string, as the mysql client reads it from the server's
    /// status. Read as an escape, it swallowed everything after it.
    func testReadsBackslashesTheWayTheFilesSQLModeSays() async throws {
        let viewModel = try await restore(Data(#"""
            /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
            CREATE TABLE t (id INT PRIMARY KEY, path VARCHAR(20));
            INSERT INTO t VALUES (1,'C:\\dir');
            /*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
            /*!50003 SET sql_mode              = 'NO_BACKSLASH_ESCAPES' */ ;
            DELIMITER ;;
            CREATE FUNCTION `to_slashes`(p TEXT) RETURNS text
                DETERMINISTIC
            RETURN REPLACE(p, '\', '/') ;;
            DELIMITER ;
            /*!50003 SET sql_mode              = @saved_sql_mode */ ;
            SET @OLDTMP_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_BACKSLASH_ESCAPES';
            DELIMITER //
            CREATE FUNCTION `win_dir`() RETURNS varchar(5) DETERMINISTIC RETURN 'C:\'//
            DELIMITER ;
            SET SQL_MODE=@OLDTMP_SQL_MODE;
            SET @saved_sql_mode = @@SQL_MODE, SQL_MODE = 'NO_BACKSLASH_ESCAPES';
            SET @saved_collation_connection = @@COLLATION_CONNECTION, COLLATION_CONNECTION = 'utf8mb4_general_ci';
            DELIMITER $$

            CREATE PROCEDURE `p_nbe`() BEGIN SELECT 'C:\'; END$$

            DELIMITER ;
            SET SQL_MODE = @saved_sql_mode, COLLATION_CONNECTION = @saved_collation_connection;
            INSERT INTO t VALUES (2,'it\'s');
            /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
            """#.utf8)) { $0.readChunkSize = 7 }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.statementErrors, [])
        let routines = try await service.query("""
            SELECT ROUTINE_NAME AS name FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '\(database)' AND SQL_MODE = 'NO_BACKSLASH_ESCAPES' ORDER BY 1
            """).compactMap { $0.column("name")?.string }
        XCTAssertEqual(routines, ["p_nbe", "to_slashes", "win_dir"])
        let results = try await service.query("SELECT `\(database)`.to_slashes(CONCAT('a', CHAR(92), 'b')) AS s, `\(database)`.win_dir() AS w").first
        XCTAssertEqual(results?.column("s")?.string, "a/b")
        XCTAssertEqual(results?.column("w")?.string, #"C:\"#)
        let paths = try await service.query("SELECT path FROM `\(database)`.t ORDER BY id").compactMap { $0.column("path")?.string }
        XCTAssertEqual(paths, [#"C:\dir"#, "it's"])
    }

    /// mysqldump wraps trigger and view bodies in executable comments, which
    /// the server and the mysql client read as SQL: a `*/` in one of their
    /// strings doesn't end the comment. Ending it there, the string's own
    /// closing quote opened one that swallowed the rest of the file.
    func testReadsTheInsideOfAnExecutableCommentAsSQL() async throws {
        let viewModel = try await restore(Data(#"""
            CREATE TABLE notes (id INT PRIMARY KEY, body TEXT, path VARCHAR(100));
            INSERT INTO notes VALUES (1,'a b','C:\\dir\\file');
            /*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
            /*!50003 SET sql_mode              = 'NO_BACKSLASH_ESCAPES' */ ;
            DELIMITER ;;
            /*!50003 CREATE*/ /*!50017 DEFINER=CURRENT_USER*/ /*!50003 TRIGGER notes_bi BEFORE INSERT ON notes FOR EACH ROW SET NEW.path = REPLACE(NEW.path, '\', '/') */;;
            DELIMITER ;
            /*!50003 SET sql_mode              = @saved_sql_mode */ ;
            DELIMITER ;;
            /*!50003 CREATE*/ /*!50017 DEFINER=CURRENT_USER*/ /*!50003 TRIGGER notes_bu BEFORE UPDATE ON notes FOR EACH ROW SET NEW.body = REPLACE(NEW.body, '*/', '') */;;
            DELIMITER ;
            /*!50001 CREATE ALGORITHM=UNDEFINED */
            /*!50001 VIEW `v_file` AS select `notes`.`id` AS `id`,regexp_replace(`notes`.`path`,'^.*/','') AS `file` from `notes` */;
            /*!50001 CREATE ALGORITHM=UNDEFINED */
            /*!50001 VIEW `v_marked` AS select `notes`.`id` AS `id`,concat('/* ',`notes`.`body`,' */') AS `marked` from `notes` */;
            CREATE TABLE zeta (id INT PRIMARY KEY);
            INSERT INTO zeta VALUES (1),(2);
            """#.utf8)) { $0.readChunkSize = 7 }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.statementErrors, [])
        let restored = try await ids(in: "zeta")
        XCTAssertEqual(restored, [1, 2])
        // Both triggers and both views work as their bodies say.
        _ = try await service.rawQuery("INSERT INTO `\(database)`.notes VALUES (2, 'x', CONCAT('D:', CHAR(92), 'new'))")
        _ = try await service.rawQuery("UPDATE `\(database)`.notes SET body = 'c */ d' WHERE id = 1")
        let rows = try await service.query("""
            SELECT CONCAT_WS('|', marked, file) AS r FROM `\(database)`.v_marked JOIN `\(database)`.v_file USING (id) ORDER BY id
            """).compactMap { $0.column("r")?.string }
        XCTAssertEqual(rows, [#"/* c  d */|C:\dir\file"#, "/* x */|new"])
    }

    /// A `use db` line without a semicolon is a command of its own to the
    /// MariaDB client. Read as the start of the next statement, it was
    /// skipped along with that statement, and the row never restored.
    func testRunsTheStatementAfterAUseLineWithoutASemicolon() async throws {
        let viewModel = try await restore(Data("""
            CREATE TABLE settings (id INT PRIMARY KEY, v VARCHAR(5));
            use shop
            INSERT INTO settings VALUES (1, 'x');
            INSERT INTO settings VALUES (2, 'y');
            """.utf8))

        XCTAssertNil(viewModel.errorMessage)
        let restored = try await ids(in: "settings")
        XCTAssertEqual(restored, [1, 2])
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

    /// The restore starts in the chosen database, whatever the connection
    /// logged in to. With the file deciding, a file with no USE (a plain
    /// `mysqldump db`) went into the profile's database and replaced its
    /// tables; and once that database was dropped, no restore could start.
    func testStartsInTheChosenDatabaseNotTheConnectionsDefault() async throws {
        _ = try await service.rawQuery("CREATE DATABASE `\(other)`")
        _ = try await service.rawQuery("CREATE TABLE `\(other)`.t (id INT PRIMARY KEY)")
        _ = try await service.rawQuery("INSERT INTO `\(other)`.t VALUES (99)")
        let profile = MySQLService()
        try await profile.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username,
                                  password: TestDatabase.password, database: other)
        addTeardownBlock { try? await profile.disconnect() }
        let dump = Data("DROP TABLE IF EXISTS t;\nCREATE TABLE t (id INT PRIMARY KEY);\nINSERT INTO t VALUES (7);\n".utf8)

        let followingTheFile = try await restore(dump, using: profile) { $0.useDatabaseNamedInFile = true }
        XCTAssertNil(followingTheFile.errorMessage)
        let restored = try? await ids(in: "t")
        XCTAssertEqual(restored, [7])
        let profilesRows = try await service.query("SELECT id FROM `\(other)`.t").compactMap { $0.column("id")?.int }
        XCTAssertEqual(profilesRows, [99], "the profile's own database must be left alone")

        _ = try await service.rawQuery("DROP DATABASE `\(other)`")
        let afterItsDrop = try await restore(dump, using: profile)
        XCTAssertNil(afterItsDrop.errorMessage)
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
