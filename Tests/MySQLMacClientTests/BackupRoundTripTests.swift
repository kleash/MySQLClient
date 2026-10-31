import XCTest
@testable import MySQLMacClient

/// End-to-end proof that a backup restores to exactly what was backed up.
///
/// Builds a schema of edge cases that dump tools are known to get wrong,
/// backs it up with `DatabaseBackupViewModel`, drops it, replays the file,
/// and compares a fingerprint of the server's own view of every object
/// before and after: `SHOW CREATE` output for each table, view, trigger,
/// routine and event, plus `CHECKSUM TABLE` and the row count of every
/// table. The fingerprint never goes through the backup code, so a value
/// that comes back different is caught even when the dump "looks" right.
@MainActor
final class BackupRoundTripTests: XCTestCase {
    private let database = "mysqlmacclient_roundtrip"
    private var service: MySQLService!
    private var dumpURL: URL!

    override func setUp() async throws {
        dumpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sql")
        service = try await connect()
        _ = try await service.rawQuery("DROP DATABASE IF EXISTS `\(database)`")
        _ = try await service.rawQuery("CREATE DATABASE `\(database)`")
        _ = try await service.rawQuery("USE `\(database)`")
        for statement in Self.corpus {
            do {
                _ = try await service.rawQuery(statement)
            } catch {
                XCTFail("Fixture failed: \(statement)\n\(error)")
                throw error
            }
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dumpURL)
        _ = try? await service.rawQuery("DROP DATABASE IF EXISTS `\(database)`")
        try await service.disconnect()
    }

    func testBackupRestoresEveryObjectAndRowExactly() async throws {
        let before = try await fingerprint()
        try await backUp()

        _ = try await service.rawQuery("DROP DATABASE `\(database)`")
        try await restore()

        let after = try await fingerprint()
        for key in Set(before.keys).union(after.keys).sorted() {
            XCTAssertEqual(after[key], before[key], key)
        }
    }

    // MARK: - Steps

    private func connect() async throws -> MySQLService {
        let service = MySQLService()
        try await service.connect(
            host: TestDatabase.host,
            port: TestDatabase.port,
            username: TestDatabase.username,
            password: TestDatabase.password,
            database: nil
        )
        return service
    }

    /// Everything selected, default options except a tiny page size, so
    /// every table with more than a few rows is read across pages.
    private func backUp() async throws {
        let viewModel = DatabaseBackupViewModel(service: service, database: DatabaseInfo(name: database))
        await viewModel.loadDatabasesAndObjects()
        viewModel.dataPageSize = 7
        viewModel.outputFileURL = dumpURL
        viewModel.outputLocationIsGranted = true
        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.loadWarning)
    }

    /// Replays the file statement by statement the way the `mysql` client
    /// would, on a separate connection.
    private func restore() async throws {
        let target = try await connect()
        defer { Task { try? await target.disconnect() } }

        let script = try String(contentsOf: dumpURL, encoding: .utf8)
        for statement in DelimiterScript.allStatements(from: script) {
            do {
                _ = try await target.rawQuery(statement)
            } catch {
                XCTFail("Restore failed at: \(statement.prefix(300))\n\(error)")
                throw error
            }
        }
    }

    // MARK: - Fingerprint

    /// What the server reports about every object in the database, keyed
    /// by a readable name so a failure says which object and which aspect
    /// differ.
    private func fingerprint() async throws -> [String: String] {
        // `SHOW CREATE VIEW` qualifies names unless the view's database is
        // the current one, and dropping a database leaves none current.
        _ = try await service.rawQuery("USE `\(database)`")
        var result: [String: String] = [:]
        let objects = try await service.rawQuery("""
            SELECT TABLE_NAME AS name, TABLE_TYPE AS type FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '\(database)'
            """).rows
        for object in objects {
            let name = try XCTUnwrap(object.column("name")?.string)
            let quoted = "`\(database)`.`\(name.replacingOccurrences(of: "`", with: "``"))`"
            if object.column("type")?.string == "VIEW" {
                result["view \(name)"] = try await showCreate("SHOW CREATE VIEW \(quoted)")
                continue
            }
            result["table \(name)"] = try await showCreate("SHOW CREATE TABLE \(quoted)")
            let checksum = try await service.rawQuery("CHECKSUM TABLE \(quoted)").rows.first
            result["table \(name) checksum"] = checksum?.column("Checksum")?.string
            let count = try await service.rawQuery("SELECT COUNT(*) AS n FROM \(quoted)").rows.first
            result["table \(name) rows"] = count?.column("n")?.string
        }

        let triggers = try await service.rawQuery("""
            SELECT TRIGGER_NAME AS name, ACTION_ORDER AS action_order FROM information_schema.TRIGGERS
            WHERE TRIGGER_SCHEMA = '\(database)'
            """).rows
        for trigger in triggers {
            let name = try XCTUnwrap(trigger.column("name")?.string)
            result["trigger \(name)"] = try await showCreate("SHOW CREATE TRIGGER `\(database)`.`\(name)`")
            result["trigger \(name) order"] = trigger.column("action_order")?.string
        }

        let routines = try await service.rawQuery("""
            SELECT ROUTINE_NAME AS name, ROUTINE_TYPE AS type FROM information_schema.ROUTINES
            WHERE ROUTINE_SCHEMA = '\(database)'
            """).rows
        for routine in routines {
            let name = try XCTUnwrap(routine.column("name")?.string)
            let type = try XCTUnwrap(routine.column("type")?.string)
            result["\(type.lowercased()) \(name)"] = try await showCreate("SHOW CREATE \(type) `\(database)`.`\(name)`")
        }

        let events = try await service.rawQuery("""
            SELECT EVENT_NAME AS name FROM information_schema.EVENTS WHERE EVENT_SCHEMA = '\(database)'
            """).rows
        for event in events {
            let name = try XCTUnwrap(event.column("name")?.string)
            result["event \(name)"] = try await showCreate("SHOW CREATE EVENT `\(database)`.`\(name)`")
        }
        return result
    }

    /// Every column of a `SHOW CREATE …` row — the statement itself and the
    /// `sql_mode`, time zone and character set it was created under —
    /// except when it was created.
    private func showCreate(_ sql: String) async throws -> String {
        let rows = try await service.rawQuery(sql).rows
        let row = try XCTUnwrap(rows.first, sql)
        return row.columnDefinitions
            .filter { $0.name != "Created" }
            .map { "\($0.name)=\(row.column($0.name)?.string ?? "NULL")" }
            .joined(separator: "\n")
    }

    // MARK: - Corpus

    /// Runs on MySQL and MariaDB alike.
    private static let corpus: [String] = [
        // AUTO_INCREMENT: gaps and a counter above the highest id, on a
        // primary key and on a column that isn't one.
        "CREATE TABLE ai_counter (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, label VARCHAR(20)) AUTO_INCREMENT = 1000",
        "INSERT INTO ai_counter VALUES (5, 'five'), (7, 'seven')",
        "CREATE TABLE ai_not_primary (code VARCHAR(10) NOT NULL PRIMARY KEY, seq INT NOT NULL AUTO_INCREMENT, UNIQUE KEY (seq))",
        "INSERT INTO ai_not_primary VALUES ('b', 3), ('a', 9)",

        // Integers at the edges of their types.
        "CREATE TABLE integers (id INT PRIMARY KEY, big BIGINT, tiny TINYINT, small_unsigned SMALLINT UNSIGNED)",
        """
        INSERT INTO integers VALUES
            (1, -9223372036854775808, -128, 65535),
            (2, 9223372036854775807, 127, 0),
            (3, NULL, NULL, NULL)
        """,

        // Foreign keys: a child that sorts before its parent, and a table
        // that references itself.
        "CREATE TABLE z_parent (id INT PRIMARY KEY) ENGINE=InnoDB",
        "CREATE TABLE a_child (id INT PRIMARY KEY, parent_id INT, FOREIGN KEY (parent_id) REFERENCES z_parent (id) ON DELETE CASCADE) ENGINE=InnoDB",
        "CREATE TABLE tree (id INT PRIMARY KEY, parent_id INT NULL, FOREIGN KEY (parent_id) REFERENCES tree (id)) ENGINE=InnoDB",
        "INSERT INTO z_parent VALUES (1), (2)",
        "INSERT INTO a_child VALUES (10, 1), (11, 2)",
        "INSERT INTO tree VALUES (1, NULL), (2, 1), (3, 2)",
        "CREATE TABLE checked (id INT PRIMARY KEY, qty INT, CONSTRAINT qty_not_negative CHECK (qty >= 0))",
        "INSERT INTO checked VALUES (1, 0), (2, 5)",

        // Paging: rows across several pages, by a composite key.
        "CREATE TABLE composite_key (a INT, b VARCHAR(10), v INT, PRIMARY KEY (a, b))",
        "INSERT INTO composite_key VALUES (1, 'a', 1), (1, 'b', 2), (1, 'c', 3), (2, 'a', 4), (2, 'b', 5), (3, 'a', 6), (3, 'b', 7), (3, 'c', 8), (4, 'a', 9), (5, 'a', 10)",

        // Names that need quoting.
        "CREATE TABLE `select` (`from` INT PRIMARY KEY, `order` VARCHAR(5))",
        "INSERT INTO `select` VALUES (1, 'x')",

        // A view, and routines.
        "CREATE VIEW positive_checks AS SELECT id, qty FROM checked WHERE qty > 0",
        """
        CREATE PROCEDURE add_one(IN p_in INT, OUT p_out INT)
        BEGIN
            SET p_out = p_in + 1;
        END
        """,
        "CREATE FUNCTION doubled(p INT) RETURNS INT DETERMINISTIC RETURN p * 2",
    ]
}
