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
///
/// Both sessions are set up unlike the server's defaults on purpose
/// (another time zone and `ANSI_QUOTES` while reading; another time zone,
/// `NO_BACKSLASH_ESCAPES`, zero dates refused and latin1 while restoring):
/// a dump has to carry every setting its contents depend on, because the
/// server it's restored on may differ.
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
        // Reading in another time zone and with ANSI_QUOTES must not change
        // what the file says.
        _ = try await service.rawQuery("SET SESSION time_zone = '-08:00', sql_mode = 'ANSI_QUOTES'")
        try await backUp()
        let readingSession = try await service.textQuery("SELECT @@SESSION.time_zone AS tz, @@SESSION.sql_mode AS mode").first
        XCTAssertEqual(readingSession?.column("tz")?.string, "-08:00", "the backup must hand the session back as it found it")
        XCTAssertEqual(readingSession?.column("mode")?.string, "ANSI_QUOTES")
        _ = try await service.rawQuery("SET SESSION time_zone = DEFAULT, sql_mode = DEFAULT")

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
    /// would, on a separate connection set up unlike the source server.
    private func restore() async throws {
        let target = try await connect()
        defer { Task { try? await target.disconnect() } }
        _ = try await target.rawQuery("SET SESSION time_zone = '+05:30'")
        _ = try await target.rawQuery("SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES,STRICT_ALL_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE'")
        _ = try await target.rawQuery("SET NAMES latin1")

        // Carries on past a failed statement, so one run reports every
        // statement the file gets wrong and still compares every object.
        let script = try String(contentsOf: dumpURL, encoding: .utf8)
        for statement in DelimiterScript.allStatements(from: script) {
            do {
                _ = try await target.rawQuery(statement)
            } catch {
                XCTFail("Restore failed at: \(statement.prefix(300))\n\(error)")
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
        // AUTO_INCREMENT: an explicit id 0 (renumbered on restore unless the
        // dump sets NO_AUTO_VALUE_ON_ZERO), gaps, and a counter above the
        // highest id, on a primary key and on a column that isn't one.
        "CREATE TABLE ai_counter (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, label VARCHAR(20)) AUTO_INCREMENT = 1000",
        "SET SESSION sql_mode = 'NO_AUTO_VALUE_ON_ZERO'",
        "INSERT INTO ai_counter VALUES (0, 'zero'), (5, 'five'), (7, 'seven')",
        "SET SESSION sql_mode = DEFAULT",
        "CREATE TABLE ai_not_primary (code VARCHAR(10) NOT NULL PRIMARY KEY, seq INT NOT NULL AUTO_INCREMENT, UNIQUE KEY (seq))",
        "INSERT INTO ai_not_primary VALUES ('b', 3), ('a', 9)",

        // Numbers at the edges of their types.
        """
        CREATE TABLE numbers (
            id INT PRIMARY KEY, wide DECIMAL(65,30), money DECIMAL(20,6), negative DECIMAL(10,2),
            ubig BIGINT UNSIGNED, sbig BIGINT, small_unsigned SMALLINT UNSIGNED, tiny TINYINT,
            flag BIT(1), mask BIT(64), f FLOAT, d DOUBLE, y YEAR
        )
        """,
        """
        INSERT INTO numbers VALUES
            (1, '12345678901234567890123456789012345.123456789012345678901234567890', '99999999999999.999999', -0.01,
             18446744073709551615, -9223372036854775808, 65535, -128,
             b'1', b'1111111111111111111111111111111111111111111111111111111111111111', 1.2345678, 0.30000000000000004, 2155),
            (2, 0, 0.000001, 0, 0, 9223372036854775807, 0, 127, b'0', b'1010', 16777216, 1.7976931348623157e308, 1901),
            (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, -3.4e38, NULL, NULL),
            (4, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
        """,
        "CREATE TABLE float_key (f FLOAT PRIMARY KEY)",
        "INSERT INTO float_key VALUES " + (1...20).map { "(\(Double($0) + 0.1234567))" }.joined(separator: ", "),

        // Dates and times: fractions of a second, TIME beyond a day and
        // below zero, zero dates, and a TIMESTAMP (stored as UTC, read and
        // written in the session's time zone).
        """
        CREATE TABLE temporal (
            id INT PRIMARY KEY, fine DATETIME(6), plain DATETIME, stamp TIMESTAMP(3) NULL, day DATE,
            duration TIME(6), negative TIME, zero_datetime DATETIME NULL, zero_date DATE NULL
        )
        """,
        """
        INSERT INTO temporal VALUES
            (1, '2024-02-29 23:59:59.123456', '1000-01-01 00:00:00', '2024-03-31 01:30:00.500', '9999-12-31',
             '838:59:59.000000', '-12:30:00', '0000-00-00 00:00:00', '0000-00-00'),
            (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
        """,

        // Strings: multi-byte text, another character set, binary with
        // trailing zero bytes, bytes that aren't UTF-8 next to bytes that
        // are, and every character a SQL literal has to escape.
        """
        CREATE TABLE strings (
            id INT PRIMARY KEY, utf VARCHAR(50) CHARACTER SET utf8mb4, latin VARCHAR(50) CHARACTER SET latin1,
            fixed CHAR(5), bin VARBINARY(10), raw BLOB, txt TEXT, choice ENUM('a', 'b,c', 'd''e'), flags SET('x', 'y', 'z')
        )
        """,
        """
        INSERT INTO strings VALUES
            (1, '😀 ünïcödé 中文', 'café', 'ab', X'00410000', X'FFFE00C3',
             CONCAT('quote '' backslash \\\\ nul ', CHAR(0), ' ctrl-z ', CHAR(26), ' crlf ', CHAR(13), CHAR(10), ' tab ', CHAR(9)),
             'b,c', 'x,z'),
            (2, '', '', '', X'', X'68656C6C6F', '', 'd''e', ''),
            (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
        """,
        "CREATE TABLE big_blob (id INT PRIMARY KEY, payload LONGBLOB)",
        "INSERT INTO big_blob VALUES (1, REPEAT(X'00FF7F80', 786432))",
        "CREATE TABLE shapes (id INT PRIMARY KEY, shape GEOMETRY NULL)",
        "INSERT INTO shapes VALUES (1, ST_GeomFromText('POINT(1.5 -2.25)')), (2, ST_GeomFromText('LINESTRING(0 0, 1 1, 2 0)')), (3, NULL)",

        // Generated columns, which an INSERT must not name.
        "CREATE TABLE computed (id INT PRIMARY KEY, a INT, doubled INT AS (a * 2) VIRTUAL, plus_one INT AS (a + 1) STORED)",
        "INSERT INTO computed (id, a) VALUES (1, 10), (2, NULL)",

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

        // Paging: rows across many pages with no key to seek on (including
        // exact duplicates), by a composite key, and by keys a rounded
        // literal would never get past.
        "CREATE TABLE no_key (v INT, w VARCHAR(10))",
        "INSERT INTO no_key VALUES " + (0..<30).map { "(\($0 % 4), 'dup')" }.joined(separator: ", "),
        "CREATE TABLE composite_key (a INT, b VARCHAR(10), v INT, PRIMARY KEY (a, b))",
        "INSERT INTO composite_key VALUES (1, 'a', 1), (1, 'b', 2), (1, 'c', 3), (2, 'a', 4), (2, 'b', 5), (3, 'a', 6), (3, 'b', 7), (3, 'c', 8), (4, 'a', 9), (5, 'a', 10)",
        "CREATE TABLE fractional_key (at DATETIME(6) PRIMARY KEY, v INT)",
        "INSERT INTO fractional_key VALUES " + (1...20).map { "('2024-01-01 00:00:00.\(String(format: "%06d", $0))', \($0))" }.joined(separator: ", "),
        "CREATE TABLE decimal_key (k DECIMAL(30,20) PRIMARY KEY, v INT)",
        "INSERT INTO decimal_key VALUES " + (1...20).map { "(1.\(String(format: "%020d", $0)), \($0))" }.joined(separator: ", "),

        // Names that need quoting.
        "CREATE TABLE `select` (`from` INT PRIMARY KEY, `order` VARCHAR(5))",
        "INSERT INTO `select` VALUES (1, 'x')",
        "CREATE TABLE `odd``name` (`col``tick` INT PRIMARY KEY)",
        "INSERT INTO `odd``name` VALUES (1), (2)",
        "CREATE VIEW `odd``view` AS SELECT `col``tick` FROM `odd``name`",

        // A view, and routines: one created under modes of its own (the
        // server keeps them with it, and ANSI_QUOTES makes "x" a name) and
        // a connection collation that isn't the server's default.
        "CREATE VIEW positive_checks AS SELECT id, qty FROM checked WHERE qty > 0",
        "SET SESSION sql_mode = 'ANSI_QUOTES,PIPES_AS_CONCAT', collation_connection = 'utf8mb4_unicode_ci'",
        """
        CREATE FUNCTION label_of(p INT) RETURNS VARCHAR(40) DETERMINISTIC
        RETURN (SELECT 'id ' || "id" FROM "checked" WHERE "id" = p)
        """,
        "SET SESSION sql_mode = DEFAULT",
        "SET NAMES utf8mb4",
        """
        CREATE PROCEDURE add_one(IN p_in INT, OUT p_out INT)
        BEGIN
            SET p_out = p_in + 1;
        END
        """,
        "CREATE FUNCTION doubled(p INT) RETURNS INT DETERMINISTIC RETURN p * 2",
    ]
}
