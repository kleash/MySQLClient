import XCTest
@testable import MySQLMacClient

/// End-to-end proof that a backup restores to exactly what was backed up.
///
/// Builds a schema of edge cases that dump tools are known to get wrong,
/// backs it up with `DatabaseBackupViewModel`, drops it, replays the file,
/// and compares a fingerprint of the server's own view of every object
/// before and after: `SHOW CREATE` output for each table, sequence, view,
/// routine and event, a trigger's row in information_schema, whether a view
/// takes a DELETE, plus `CHECKSUM TABLE` and the row count of every table.
/// The fingerprint never goes through the backup code, so a value that
/// comes back different is caught even when the dump "looks" right.
///
/// Both sessions are set up unlike the server's defaults on purpose
/// (another time zone and `ANSI_QUOTES` while reading; another time zone,
/// `NO_BACKSLASH_ESCAPES`, zero dates refused and latin1 while restoring):
/// a dump has to carry every setting its contents depend on, because the
/// server it's restored on may differ.
///
/// The same comparison checks backups made with mysqldump and restores run
/// by the mysql client, each with the other engine as well.
@MainActor
class BackupRoundTripTests: XCTestCase {
    private let database = "mysqlmacclient_roundtrip"
    private let copy = "mysqlmacclient_roundtrip_copy"
    private var service: MySQLService!
    private var dumpURL: URL!

    override func setUp() async throws {
        dumpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sql")
        service = try await connect()
        // Both, in case a run that was stopped never got to tearDown.
        _ = try await service.rawQuery("DROP DATABASE IF EXISTS `\(database)`")
        _ = try await service.rawQuery("DROP DATABASE IF EXISTS `\(copy)`")
        _ = try await service.rawQuery("CREATE DATABASE `\(database)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        _ = try await service.rawQuery("USE `\(database)`")
        let isMariaDB = await service.serverVersion?.contains("MariaDB") ?? false
        let fixtures = Self.corpus + Self.schemaObjectCorpus
            + (isMariaDB ? Self.mariaDBCorpus + Self.mariaDBSchemaObjectCorpus : [])
        for statement in fixtures {
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
        guard let service else { return }
        _ = try? await service.rawQuery("DROP DATABASE IF EXISTS `\(database)`")
        _ = try? await service.rawQuery("DROP DATABASE IF EXISTS `\(copy)`")
        try await service.disconnect()
    }

    func testBackupRestoresEveryObjectAndRowExactly() async throws {
        let before = try await fingerprint(of: database)
        // Another time zone, ANSI_QUOTES and latin1 on the app's connection
        // must not change what the file says.
        _ = try await service.rawQuery("SET SESSION time_zone = '-08:00', sql_mode = 'ANSI_QUOTES'")
        _ = try await service.rawQuery("SET NAMES latin1")
        try await backUp()
        let readingSession = try await service.textQuery("SELECT @@SESSION.time_zone AS tz, @@SESSION.sql_mode AS mode").first
        XCTAssertEqual(readingSession?.column("tz")?.string, "-08:00", "the backup must hand the session back as it found it")
        XCTAssertEqual(readingSession?.column("mode")?.string, "ANSI_QUOTES")
        _ = try await service.rawQuery("SET SESSION time_zone = DEFAULT, sql_mode = DEFAULT")
        _ = try await service.rawQuery("SET NAMES utf8mb4")

        _ = try await service.rawQuery("DROP DATABASE `\(database)`")
        try await restore()

        assertSame(try await fingerprint(of: database), before)
    }

    /// Without its CREATE DATABASE and USE, a backup restores into whichever
    /// database is current — here one next to the original, which must
    /// come out the same and leave the original untouched.
    func testBackupRestoresIntoAnotherDatabase() async throws {
        let before = try await fingerprint(of: database)
        try await backUp {
            $0.file.includeCreateDatabaseStatement = false
            $0.file.includeUseStatement = false
        }
        _ = try await service.rawQuery("CREATE DATABASE `\(copy)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        try await restore(into: copy)

        assertSame(try await fingerprint(of: database), before)
        var restored = try await fingerprint(of: copy)
        var original = before
        restored["database"] = nil
        original["database"] = nil
        assertSame(restored, original)
    }

    /// The app's own restore (`DatabaseRestoreViewModel`) of a default
    /// backup, into another database made with the server's defaults: it
    /// has to skip the file's USE and CREATE DATABASE but give the copy
    /// the original's character set and collation, and come out the same
    /// reading the file in chunks small enough to cut every statement,
    /// string and character.
    func testBackupRestoredWithTheAppIntoAnotherDatabaseMatchesTheOriginal() async throws {
        let before = try await fingerprint(of: database)
        try await backUp()
        try await assertRestoredCopyMatches(before)
    }

    /// Each page of a composite key is read as a range of the key's index:
    /// about one row read per row written. Reading every page from the start
    /// of the key (MariaDB does that for `(a, b) > (x, y)`) or sorting the
    /// table for each page (ordering by the columns in table order instead
    /// of the key's does that) reads tens of times more.
    func testPagesOfACompositeKeyAreRangesOfItsIndex() async throws {
        let viewModel = DatabaseBackupViewModel(service: service, database: DatabaseInfo(name: database))
        await viewModel.loadDatabasesAndObjects()
        viewModel.selectNoObjects()
        viewModel.selectedTables = Set(viewModel.allTables.filter { $0.name == "reversed_key" })
        viewModel.options.mode = .dataOnly
        viewModel.dataPageSize = 7
        viewModel.outputFileURL = dumpURL
        viewModel.outputLocationIsGranted = true
        // Server-wide: the backup reads on a connection of its own.
        func readsSoFar() async throws -> Int {
            try await service.textQuery("SHOW GLOBAL STATUS WHERE Variable_name IN ('Handler_read_next', 'Handler_read_rnd_next')")
                .compactMap { $0.column("Value")?.string.flatMap { Int($0) } }
                .reduce(0, +)
        }
        let before = try await readsSoFar()
        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }
        XCTAssertNil(viewModel.errorMessage)

        let reads = try await readsSoFar() - before
        XCTAssertLessThan(reads, 7_000, "700 rows")
    }

    /// Locking tables instead of reading one snapshot, from a connection
    /// with no database of its own selected.
    func testBackupLockingTablesRestoresEveryObjectAndRowExactly() async throws {
        let before = try await fingerprint(of: database)
        try await backUp { $0.source.lockTablesForReading = true }
        _ = try await service.rawQuery("DROP DATABASE `\(database)`")
        try await restore()

        assertSame(try await fingerprint(of: database), before)
    }

    /// Structure only: every definition comes back, and no table's rows but
    /// a sequence's one row, which holds its definition as well as where it
    /// has got to.
    func testStructureOnlyBackupRestoresEveryDefinition() async throws {
        let before = try await fingerprint(of: database)
        try await backUp { $0.mode = .structureOnly }
        _ = try await service.rawQuery("DROP DATABASE `\(database)`")
        try await restore()

        // Without what's in each table, which structure only leaves out.
        func structure(_ fingerprint: [String: String]) -> [String: String] {
            fingerprint.filter { key, _ in
                !(key.hasPrefix("table ") && [" checksum", " rows", " as printed"].contains(where: key.hasSuffix))
            }
        }
        assertSame(structure(try await fingerprint(of: database)), structure(before))
    }

    // MARK: - mysqldump and the mysql client

    /// A mysqldump backup recreates the database it was made from, with its
    /// default character set, when the mysql client runs it as it is.
    func testMysqldumpBackupRestoredWithTheMysqlClientRecreatesTheDatabase() async throws {
        try await dropWhatMysqldumpLoses()
        let before = try await fingerprint(of: database)
        try await backUpWithMysqldump()
        try await recreateWithTheMysqlClient()

        assertSame(await mysqldumpKeeps(try await fingerprint(of: database)), await mysqldumpKeeps(before))
    }

    func testMysqldumpBackupRestoredWithTheAppIntoAnotherDatabaseMatches() async throws {
        try await dropWhatMysqldumpLoses()
        let before = try await fingerprint(of: database)
        try await backUpWithMysqldump()
        try await assertRestoredCopyMatches(before, madeWithMysqldump: true)
    }

    func testBackupRestoredWithTheMysqlClientRecreatesTheDatabase() async throws {
        let before = try await fingerprint(of: database)
        try await backUp()
        try await recreateWithTheMysqlClient()

        assertSame(try await fingerprint(of: database), before)
    }

    /// Drops the database and has the mysql client run the backup as it is,
    /// from the sheet of another database (the sheet always opens on one
    /// that exists): the file's own CREATE DATABASE and USE bring it back.
    private func recreateWithTheMysqlClient() async throws {
        _ = try await service.rawQuery("DROP DATABASE `\(database)`")
        _ = try await service.rawQuery("CREATE DATABASE `\(copy)`")
        try await restoreWithTheApp(into: copy, usesExternalTool: true, useDatabaseNamedInFile: true)
    }

    /// Restores the backup with the built-in engine into a new database next
    /// to the original, made with the server's defaults, with the dialog's
    /// defaults (the file's own USE and CREATE DATABASE skipped, its
    /// character set and collation given to the copy), and compares both
    /// with `before`.
    private func assertRestoredCopyMatches(_ before: [String: String], madeWithMysqldump: Bool = false,
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = try await service.rawQuery("CREATE DATABASE `\(copy)`")
        try await restoreWithTheApp(into: copy, usesExternalTool: false)

        assertSame(try await fingerprint(of: database), before, file: file, line: line)
        var restored = try await fingerprint(of: copy)
        restored["database"] = restored["database"]?.replacingOccurrences(of: copy, with: database)
        var original = before
        if madeWithMysqldump {
            restored = await mysqldumpKeeps(restored)
            original = await mysqldumpKeeps(original)
        }
        assertSame(restored, original, file: file, line: line)
    }

    /// What mysqldump loses that the built-in engine keeps, dropped before a
    /// mysqldump round trip so that everything else is compared exactly.
    private func dropWhatMysqldumpLoses() async throws {
        for statement in [
            // MySQL's mysqldump asks MariaDB for a collation it doesn't know,
            // reads names in latin1, and fails the backup on this one.
            "DROP TABLE `tick``\u{301}mark`",
            // An ENUM's error value and a SET's '' member, both written as ''.
            "DROP TABLE empty_member",
            // Dates that don't exist, zero dates under the file's SQL mode.
            "DROP TABLE invalid_dates",
            // -0, written as the integer, which reads back as 0.
            "DROP TABLE negative_zero",
            // Created on a stand-in for the view they're built on: never
            // updatable again, and WITH CHECK OPTION refused.
            "DROP VIEW a_view_on_view, a_checked_on_view",
            // MariaDB's SHOW CREATE TRIGGER, as typed, names this database:
            // restored into another one, it comes back here.
            "DROP TRIGGER qualified_trigger",
            // Its LOCK TABLES around the rows leaves out the sequence their
            // DEFAULT takes numbers from (MariaDB only).
            "DROP TABLE IF EXISTS a_uses_sequence",
        ] {
            _ = try await service.rawQuery(statement)
        }
    }

    /// What a mysqldump backup keeps of `fingerprint`. mysqldump writes
    /// every value the way the server prints it, and MariaDB prints a FLOAT
    /// to 6 significant digits (16777216 as 16777200, 1.2345678 as
    /// 1.23457), so there FLOAT values come back as printed, not as they
    /// were: a table with FLOAT columns (the corpus keeps them to tables of
    /// their own) is compared by its values as printed rather than by its
    /// checksum. Everything else has to come back exactly.
    private func mysqldumpKeeps(_ fingerprint: [String: String]) async -> [String: String] {
        guard await service.serverVersion?.contains("MariaDB") ?? false else { return fingerprint }
        return fingerprint.filter { key, _ in
            guard key.hasPrefix("table "), key.hasSuffix(" checksum") else { return true }
            let table = key.dropLast(" checksum".count)
            return !fingerprint.keys.contains { $0.hasPrefix(table + " ") && $0.hasSuffix(" as printed") }
        }
    }

    private func assertSame(_ actual: [String: String], _ expected: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        for key in Set(expected.keys).union(actual.keys).sorted() {
            XCTAssertEqual(actual[key], expected[key], key, file: file, line: line)
        }
    }

    // MARK: - Steps

    /// A new connection to the server under test; `SSHBackupRoundTripTests`
    /// goes through an SSH tunnel instead.
    func connect() async throws -> MySQLService {
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

    private func skipUnlessToolsAreInstalled() throws {
        guard ExternalTool.locate(.dump, configuredPath: "", preferMariaDB: true) != nil,
              ExternalTool.locate(.client, configuredPath: "", preferMariaDB: true) != nil else {
            throw XCTSkip("The MySQL or MariaDB command-line tools aren't installed.")
        }
    }

    /// The whole database with mysqldump (or mariadb-dump), as the dialog
    /// runs it.
    private func backUpWithMysqldump() async throws {
        try skipUnlessToolsAreInstalled()
        let viewModel = DatabaseBackupViewModel(service: service, database: DatabaseInfo(name: database))
        await viewModel.loadDatabasesAndObjects()
        viewModel.usesExternalTool = true
        viewModel.outputFileURL = dumpURL
        viewModel.outputLocationIsGranted = true
        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.didFinishSuccessfully)
        // The corpus has FLOAT columns: the dialog warns about them on MariaDB.
        let isMariaDB = await service.serverVersion?.contains("MariaDB") ?? false
        XCTAssertEqual(viewModel.externalToolRoundsFloats, isMariaDB)
        // The file is mysqldump's, not the built-in engine's. MariaDB's
        // starts with a line that puts the client in sandbox mode.
        let header = try FileHandle(forReadingFrom: dumpURL).read(upToCount: 200) ?? Data()
        XCTAssertTrue(String(decoding: header, as: UTF8.self).contains(" dump "), String(decoding: header, as: UTF8.self))
    }

    /// `DatabaseRestoreViewModel`, built-in or with the mysql client, reading
    /// the file in chunks small enough to cut every statement, string and
    /// character.
    private func restoreWithTheApp(into target: String, usesExternalTool: Bool, useDatabaseNamedInFile: Bool = false) async throws {
        if usesExternalTool { try skipUnlessToolsAreInstalled() }
        let restore = DatabaseRestoreViewModel(service: service, database: DatabaseInfo(name: target))
        restore.inputFileURL = dumpURL
        restore.usesExternalTool = usesExternalTool
        restore.useDatabaseNamedInFile = useDatabaseNamedInFile
        restore.readChunkSize = 7
        restore.startRestore()
        while restore.isRunning { await Task.yield() }
        XCTAssertNil(restore.errorMessage)
        XCTAssertEqual(restore.statementErrors, [])
        XCTAssertTrue(restore.didFinishSuccessfully)
        XCTAssertEqual(restore.externalToolURL != nil, usesExternalTool, "the restore must run with the engine asked for")
    }

    /// Everything selected, default options (unless `configure` changes
    /// them) and a tiny page size, so every table with more than a few rows
    /// is read across pages.
    private func backUp(configure: (inout DatabaseBackupOptions) -> Void = { _ in }) async throws {
        let viewModel = DatabaseBackupViewModel(service: service, database: DatabaseInfo(name: database))
        await viewModel.loadDatabasesAndObjects()
        configure(&viewModel.options)
        viewModel.dataPageSize = 7
        viewModel.outputFileURL = dumpURL
        viewModel.outputLocationIsGranted = true
        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.loadWarning)
    }

    /// Replays the file statement by statement the way the `mysql` client
    /// would, on a separate connection set up unlike the source server,
    /// with `database` (when given) as its current database.
    private func restore(into database: String? = nil) async throws {
        let target = try await connect()
        defer { Task { try? await target.disconnect() } }
        if let database {
            _ = try await target.rawQuery("USE `\(database)`")
        }
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
    private func fingerprint(of database: String) async throws -> [String: String] {
        // `SHOW CREATE VIEW` qualifies names unless the view's database is
        // the current one, and dropping a database leaves none current.
        _ = try await service.rawQuery("USE `\(database)`")
        var result: [String: String] = [:]
        result["database"] = try await showCreate("SHOW CREATE DATABASE `\(database)`")
        let objects = try await service.rawQuery("""
            SELECT TABLE_NAME AS name, TABLE_TYPE AS type FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = '\(database)'
            """).rows
        for object in objects {
            let name = try XCTUnwrap(object.column("name")?.string)
            let quoted = "`\(database)`.`\(name.replacingOccurrences(of: "`", with: "``", options: .literal))`"
            if object.column("type")?.string == "VIEW" {
                result["view \(name)"] = try await showCreate("SHOW CREATE VIEW \(quoted)")
                // Whether a view can be updated is decided when it's created,
                // and nothing the server reports shows it: a view created on
                // a stand-in never can be. This deletes nothing.
                let deletable = (try? await service.rawQuery("DELETE FROM \(quoted) WHERE FALSE")) != nil
                result["view \(name) deletable"] = "\(deletable)"
                continue
            }
            // MySQL 8 shows a restored column's collation as `CHARACTER SET
            // utf8mb4 COLLATE utf8mb4_unicode_ci` where the original said
            // `COLLATE utf8mb4_unicode_ci`: the same thing, since a collation
            // names its character set, so only that spelling is evened out.
            // MariaDB names the sequence a DEFAULT takes numbers from with
            // its database, which is another one in a copy. A sequence's
            // SHOW CREATE TABLE is the same for every one.
            let kind = object.column("type")?.string == "SEQUENCE" ? "sequence" : "table"
            result["\(kind) \(name)"] = try await showCreate("SHOW CREATE \(kind.uppercased()) \(quoted)")
                .replacingOccurrences(of: #"CHARACTER SET (\w+) COLLATE (\1_\w+)"#, with: "COLLATE $2", options: .regularExpression)
                .replacingOccurrences(of: "nextval(`\(database)`.", with: "nextval(")
            let checksum = try await service.rawQuery("CHECKSUM TABLE \(quoted)").rows.first
            result["\(kind) \(name) checksum"] = checksum?.column("Checksum")?.string
            let count = try await service.rawQuery("SELECT COUNT(*) AS n FROM \(quoted)").rows.first
            result["\(kind) \(name) rows"] = count?.column("n")?.string
            // FLOAT values as the server prints them (`mysqldumpKeeps`).
            let floatColumns = try await service.textQuery("""
                SELECT COLUMN_NAME AS name FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = '\(database)' AND TABLE_NAME = '\(name)' AND DATA_TYPE = 'float' ORDER BY ORDINAL_POSITION
                """).compactMap { $0.column("name")?.string }
            for column in floatColumns {
                let values = try await service.textQuery("SELECT `\(column.replacingOccurrences(of: "`", with: "``"))` AS v FROM \(quoted) ORDER BY 1")
                result["\(kind) \(name) \(column) as printed"] = values.map { $0.column("v")?.string ?? "NULL" }.joined(separator: ", ")
            }
        }

        // A trigger by its parts, the order it fires in included, rather than
        // SHOW CREATE TRIGGER: on MariaDB that's the statement as it was
        // typed, which a backup writes without the database it may name.
        let triggers = try await service.rawQuery("""
            SELECT * FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '\(database)'
            """).rows
        for trigger in triggers {
            let name = try XCTUnwrap(trigger.column("TRIGGER_NAME")?.string)
            result["trigger \(name)"] = trigger.columnDefinitions
                .filter { !["TRIGGER_SCHEMA", "EVENT_OBJECT_SCHEMA", "CREATED"].contains($0.name) }
                .map { "\($0.name)=\(trigger.column($0.name)?.string ?? "NULL")" }
                .joined(separator: "\n")
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

        // Numbers at the edges of their types, FLOAT in tables of its own
        // (see `mysqldumpKeeps`).
        """
        CREATE TABLE numbers (
            id INT PRIMARY KEY, wide DECIMAL(65,30), money DECIMAL(20,6), negative DECIMAL(10,2),
            ubig BIGINT UNSIGNED, sbig BIGINT, small_unsigned SMALLINT UNSIGNED, tiny TINYINT,
            flag BIT(1), mask BIT(64), d DOUBLE, y YEAR
        )
        """,
        """
        INSERT INTO numbers VALUES
            (1, '12345678901234567890123456789012345.123456789012345678901234567890', '99999999999999.999999', -0.01,
             18446744073709551615, -9223372036854775808, 65535, -128,
             b'1', b'1111111111111111111111111111111111111111111111111111111111111111', 0.30000000000000004, 2155),
            (2, 0, 0.000001, 0, 0, 9223372036854775807, 0, 127, b'0', b'1010', 1.7976931348623157e308, 1901),
            (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
            (4, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
        """,
        "CREATE TABLE floats (id INT PRIMARY KEY, f FLOAT)",
        "INSERT INTO floats VALUES (1, 1.2345678), (2, 16777216), (3, -3.4e38), (4, NULL)",
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
        // MySQL refuses zero dates by default.
        "SET SESSION sql_mode = ''",
        """
        INSERT INTO temporal VALUES
            (1, '2024-02-29 23:59:59.123456', '1000-01-01 00:00:00', '2024-03-31 01:30:00.500', '9999-12-31',
             '838:59:59.000000', '-12:30:00', '0000-00-00 00:00:00', '0000-00-00'),
            (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
        """,
        "SET SESSION sql_mode = DEFAULT",

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
        // JSON: a type of its own on MySQL (reported with the binary
        // character set), text with a check on MariaDB.
        "CREATE TABLE documents (id INT PRIMARY KEY, doc JSON)",
        #"INSERT INTO documents VALUES (1, '{"name": "café 😀", "quote": "it''s", "path": "C:\\\\dir", "n": 1.50, "list": [1, null, true]}'), (2, NULL)"#,
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

        // ---- Values and paging, continued ----

        // A combining mark right after a quote, a backslash or a backtick,
        // which an escape has to see as two characters.
        "CREATE TABLE combining_marks (id INT PRIMARY KEY, v VARCHAR(20))",
        "INSERT INTO combining_marks VALUES (1, 'd\u{336}o\u{336}n\u{336}''\u{336}t\u{336}'), (2, 'x\\\\\u{301}y')",
        "CREATE TABLE `tick``\u{301}mark` (id INT PRIMARY KEY)",
        "INSERT INTO `tick``\u{301}mark` VALUES (1)",

        // Keys that sort one way and compare with a literal another: ENUM
        // and SET by member number against 'text', BIT by value against
        // X'..'.
        "CREATE TABLE enum_key (u INT, role ENUM('owner', 'admin', 'member'), PRIMARY KEY (u, role))",
        "INSERT INTO enum_key VALUES " + (1...4).flatMap { u in ["owner", "admin", "member"].map { "(\(u), '\($0)')" } }.joined(separator: ", "),
        "CREATE TABLE set_key (s SET('x', 'b', 'a') PRIMARY KEY)",
        "INSERT INTO set_key VALUES " + (0...7).map { "(\($0))" }.joined(separator: ", "),
        "CREATE TABLE bit_key (b BIT(16) PRIMARY KEY)",
        "INSERT INTO bit_key VALUES " + (1...20).map { "(\($0 * 300))" }.joined(separator: ", "),
        "CREATE TABLE int_bit_key (a INT, f BIT(1), PRIMARY KEY (a, f))",
        "INSERT INTO int_bit_key VALUES " + (1...10).map { "(\($0), 0), (\($0), 1)" }.joined(separator: ", "),
        // A composite key in another order than its columns, over 100 pages
        // (see testPagesOfACompositeKeyAreRangesOfItsIndex).
        "CREATE TABLE reversed_key (a INT, b INT, PRIMARY KEY (b, a))",
        "INSERT INTO reversed_key VALUES " + (0..<700).map { "(\($0 / 10), \($0 % 10))" }.joined(separator: ", "),
        // Pages that start inside a run of one FLOAT, so the next page is
        // asked for with an equality on it.
        "CREATE TABLE inexact_composite_key (f FLOAT, at DATETIME(6), PRIMARY KEY (f, at))",
        "INSERT INTO inexact_composite_key VALUES "
            + (1...24).map { "(\(Double($0 % 3) + 0.1234567), '2024-01-01 00:00:00.\(String(format: "%06d", $0))')" }.joined(separator: ", "),
        // No key, and values the collation calls equal but whose bytes
        // differ: case, accents and trailing spaces.
        "CREATE TABLE no_key_ties (v VARCHAR(10))",
        "INSERT INTO no_key_ties VALUES " + [("a", 12), ("A", 11), ("á", 4), ("Á", 3), ("a ", 2)]
            .flatMap { Array(repeating: "('\($0)')", count: $1) }.joined(separator: ", "),

        // Negative zero, which the integer literal -0 would store as 0.
        "CREATE TABLE negative_zero (id INT PRIMARY KEY, f FLOAT, d DOUBLE)",
        "INSERT INTO negative_zero VALUES (1, -0e0, -0e0), (2, 0e0, 0e0)",

        // An ENUM and a SET that declare '', which reads the same as the
        // ENUM's error value (what an invalid value is stored as outside
        // strict mode) and the SET's empty set.
        "CREATE TABLE empty_member (id INT PRIMARY KEY, e ENUM('', 'a'), s SET('', 'a'))",
        "SET SESSION sql_mode = ''",
        "INSERT INTO empty_member VALUES (1, 'not a member', 0), (2, '', 1), (3, 'a', 3)",
        "SET SESSION sql_mode = DEFAULT",

        // Invisible columns, which SELECT * leaves out.
        "CREATE TABLE hidden_cols (id INT PRIMARY KEY, secret VARCHAR(10) INVISIBLE, n INT DEFAULT 5 INVISIBLE)",
        "INSERT INTO hidden_cols (id, secret, n) VALUES (1, 'shh', 42), (2, NULL, 7)",

        // ---- End of values and paging, continued ----

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
        // A view built on a view that sorts after it.
        "CREATE VIEW z_base_view AS SELECT id, a FROM computed",
        "CREATE VIEW a_view_on_view AS SELECT id FROM z_base_view WHERE a > 0",
        "CREATE SQL SECURITY INVOKER VIEW invoker_view AS SELECT id FROM numbers",
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

        // Triggers: two on one event, the second set to fire after the
        // first although its name sorts before it, and one with a body.
        // Restoring the rows must not fire them: audited holds a row whose
        // note they would change.
        "CREATE TABLE audited (id INT PRIMARY KEY, note VARCHAR(50))",
        "INSERT INTO audited VALUES (1, 'kept as is')",
        "CREATE TRIGGER z_first BEFORE INSERT ON audited FOR EACH ROW SET NEW.note = CONCAT(NEW.note, ';1')",
        "CREATE TRIGGER a_second BEFORE INSERT ON audited FOR EACH ROW FOLLOWS z_first SET NEW.note = CONCAT(NEW.note, ';2')",
        """
        CREATE TRIGGER audited_update BEFORE UPDATE ON audited FOR EACH ROW
        BEGIN
            -- a comment with a ; in it
            IF NEW.note IS NULL THEN SET NEW.note = 'was null; now set'; END IF;
        END
        """,

        // An event, created in a time zone of its own.
        "SET SESSION time_zone = '+03:00'",
        "CREATE EVENT nightly ON SCHEDULE EVERY 1 DAY STARTS '2030-01-01 02:00:00' DISABLE DO DELETE FROM no_key WHERE v < 0",
        "SET SESSION time_zone = DEFAULT",
    ]

    /// MariaDB-only objects.
    private static let mariaDBCorpus: [String] = [
        // A sequence that has handed out numbers: it must carry on from
        // where it was, not start over.
        "CREATE SEQUENCE order_numbers START WITH 100 INCREMENT BY 5",
        "CREATE SEQUENCE uncached START WITH 7 CACHE 0",
        "SELECT NEXTVAL(uncached)",
        "SELECT NEXTVAL(order_numbers), NEXTVAL(order_numbers)",
    ]

    // MARK: - Corpus: order and settings of schema objects

    /// Runs after `corpus`, on MySQL and MariaDB alike: objects that only
    /// restore when they're created in the right order, or under the
    /// settings they were created under.
    private static let schemaObjectCorpus: [String] = [
        // A view calling a function: CREATE VIEW checks the function exists.
        "CREATE VIEW uses_function AS SELECT id, doubled(qty) AS twice FROM checked",
        // WITH CHECK OPTION on a view built on a view that sorts after it:
        // refused while that one is a stand-in, which can't be updated.
        "CREATE VIEW a_checked_on_view AS SELECT id, a FROM z_base_view WHERE a > 0 WITH CASCADED CHECK OPTION",
        // A trigger named with its database, as the app's own Create Trigger
        // template writes one: a copy must get it, not the original a
        // second one.
        "CREATE TRIGGER `mysqlmacclient_roundtrip`.`qualified_trigger` AFTER UPDATE ON `mysqlmacclient_roundtrip`.`audited` FOR EACH ROW SET @audited_updates = 1",
        // A function, a trigger and an event created while the database's
        // default was latin1 keep it, and their parameters and variables
        // declared without a character set are latin1.
        "ALTER DATABASE CHARACTER SET latin1",
        "CREATE FUNCTION latin1_length(p VARCHAR(10)) RETURNS INT DETERMINISTIC RETURN LENGTH(p)",
        "CREATE TRIGGER latin1_trigger AFTER INSERT ON checked FOR EACH ROW SET @latin1_trigger = 1",
        "CREATE EVENT latin1_event ON SCHEDULE EVERY 1 DAY STARTS '2030-01-01 00:00:00' DISABLE DO SET @latin1_event = 1",
        "ALTER DATABASE CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci",
        // A view created under a connection collation of its own, which its
        // string literals take: 'a' = 'A' is false in it.
        "SET NAMES utf8mb4 COLLATE utf8mb4_bin",
        "CREATE VIEW binary_literals AS SELECT 'a' = 'A' AS same",
        "SET NAMES utf8mb4",
        // The database's quoted name and a dot inside string literals: only
        // a name it qualifies may lose it.
        """
        CREATE TABLE mentions_database (
            id INT PRIMARY KEY,
            note VARCHAR(80) DEFAULT 'copied from `mysqlmacclient_roundtrip`.t' COMMENT 'see `mysqlmacclient_roundtrip`.t'
        ) COMMENT = 'archive of `mysqlmacclient_roundtrip`.orders'
        """,
        "CREATE VIEW mentions_database_view AS SELECT 'see `mysqlmacclient_roundtrip`.t for it''s details' AS note",
        // Dates that don't exist, stored under ALLOW_INVALID_DATES: the
        // file's SQL mode decides whether they come back or turn into
        // zero dates.
        "SET SESSION sql_mode = 'ALLOW_INVALID_DATES'",
        "CREATE TABLE invalid_dates (id INT PRIMARY KEY, d DATE, dt DATETIME(6))",
        "INSERT INTO invalid_dates VALUES (1, '2024-02-30', '2023-04-31 23:59:59.123456')",
        "SET SESSION sql_mode = DEFAULT",
    ]

    /// MariaDB-only, after `mariaDBCorpus`.
    private static let mariaDBSchemaObjectCorpus: [String] = [
        // A table taking its key from a sequence that sorts after it: CREATE
        // TABLE checks the sequence exists.
        "CREATE SEQUENCE z_ids",
        "CREATE TABLE a_uses_sequence (id INT NOT NULL DEFAULT NEXT VALUE FOR z_ids PRIMARY KEY, v INT)",
        "INSERT INTO a_uses_sequence (v) VALUES (1), (2)",
    ]
}

/// Every round trip above through the SSH test servers (testenv's `ssh`
/// profile), to a MariaDB that only the SSH server can reach. The app
/// connects to the tunnel's local end, and so do mysqldump and the mysql
/// client.
final class SSHBackupRoundTripTests: BackupRoundTripTests {
    private var tunnel: SSHTunnel?
    private var sshFolder: URL?
    private var localPort = 0

    private var ssh: SSHSettings? {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["MYSQL_TEST_SSH_PORT"].flatMap(Int.init), let key = environment["MYSQL_TEST_SSH_KEY"] else { return nil }
        return SSHSettings(host: "127.0.0.1", port: port, username: "tunnel", keyFile: key)
    }

    override func setUp() async throws {
        guard let ssh else { throw XCTSkip("The SSH test servers aren't running (testenv/run-tests.sh starts them).") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sshFolder = folder
        let tunnel = SSHTunnel(settings: ssh, proxy: nil, sshFolder: folder)
        localPort = try await tunnel.open(to: "private-mariadb", port: 3306)
        self.tunnel = tunnel
        try await super.setUp()
    }

    override func tearDown() async throws {
        // Without a tunnel, setUp stopped before the base class set anything up.
        if tunnel != nil { try await super.tearDown() }
        tunnel?.close()
        if let sshFolder { try? FileManager.default.removeItem(at: sshFolder) }
    }

    override func connect() async throws -> MySQLService {
        let service = MySQLService()
        try await service.connect(host: "127.0.0.1", port: localPort, username: "root", password: nil, database: nil,
                                  serverName: "private-mariadb")
        return service
    }
}
