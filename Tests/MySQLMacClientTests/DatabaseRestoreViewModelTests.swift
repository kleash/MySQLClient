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

    /// A lenient decode would store U+FFFD in place of these bytes. The
    /// error names the line they are on, not just where their statement
    /// starts: in a HeidiSQL INSERT, a row per line, that can be far apart.
    func testRefusesAStatementThatIsNotUTF8InsteadOfAlteringIt() async throws {
        var contents = Data("CREATE TABLE t (id INT PRIMARY KEY, b BLOB);\nINSERT INTO t VALUES\n\t(1, 'ok'),\n\t(2, '".utf8)
        contents.append(contentsOf: [0xFF, 0xFE, 0x00, 0xC3])
        contents.append(Data("');\nINSERT INTO t VALUES (3, 'ok');\n".utf8))
        let viewModel = try await restore(contents)

        XCTAssertEqual(viewModel.failure, .notUTF8(line: 4))
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [])
    }

    /// The server numbers an error's line within the statement it was sent;
    /// the list of failed statements names the file's line.
    func testNamesTheFilesLineInAStatementsError() async throws {
        let viewModel = try await restore(Data("""
            CREATE TABLE t (id INT PRIMARY KEY);
            -- the INSERT below has a mistake on its second line
            INSERT INTO t
            VALUES (1,, 2);
            """.utf8))

        XCTAssertEqual(viewModel.statementErrors.map(\.line), [3])
        let message = try XCTUnwrap(viewModel.statementErrors.first?.message)
        XCTAssertTrue(message.hasSuffix("at line 4"), message)
    }

    /// MySQLNIO sends a statement as one packet, whose length is 3 bytes,
    /// so the server got one of 16 MiB or more cut to that length modulo
    /// 16 MiB. This one, 2^24 + 15 bytes long, reached it as `DELETE FROM
    /// big` and emptied the table. It has to be refused, unsent.
    func testRefusesAStatementTooBigToSendInsteadOfCuttingItShort() async throws {
        let delete = "DELETE FROM big WHERE id = 1 /* "
        let filler = String(repeating: "x", count: (1 << 24) + 15 - delete.utf8.count - " */".utf8.count)
        let viewModel = try await restore(Data("""
            CREATE TABLE big (id INT PRIMARY KEY);
            INSERT INTO big VALUES (1), (2), (3);
            \(delete)\(filler) */;
            INSERT INTO big VALUES (4);
            """.utf8)) { $0.readChunkSize = 1 << 25 }

        XCTAssertEqual(viewModel.failure, .statementTooLarge(line: 3))
        let restored = try await ids(in: "big")
        XCTAssertEqual(restored, [1, 2, 3])
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

    /// The file's database settings go to the chosen database instead: its
    /// own character set and collation, and those mysqldump sets around a
    /// routine made under another one. The copy's routines keep the
    /// collation they were made with (a parameter without a character set
    /// takes the database's), and the original is left alone.
    func testGivesTheChosenDatabaseTheFilesDatabaseSettings() async throws {
        _ = try await service.rawQuery("CREATE DATABASE `\(other)` CHARACTER SET latin1 COLLATE latin1_general_ci")
        let viewModel = try await restore(Data("""
            CREATE DATABASE /*!32312 IF NOT EXISTS*/ `\(other)` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci */;
            USE `\(other)`;
            CREATE FUNCTION f_len(x VARCHAR(10)) RETURNS INT DETERMINISTIC RETURN CHAR_LENGTH(x);
            ALTER DATABASE `\(other)` CHARACTER SET latin1 COLLATE latin1_swedish_ci ;
            CREATE PROCEDURE p_latin() SELECT 1;
            ALTER DATABASE `\(other)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci ;
            """.utf8))

        XCTAssertNil(viewModel.errorMessage)
        let databases = try await service.query("""
            SELECT CONCAT(SCHEMA_NAME, ' ', DEFAULT_COLLATION_NAME) AS c FROM information_schema.SCHEMATA WHERE SCHEMA_NAME IN ('\(database)', '\(other)') ORDER BY 1
            """).compactMap { $0.column("c")?.string }
        XCTAssertEqual(databases, ["\(database) utf8mb4_unicode_ci", "\(other) latin1_general_ci"])
        let routines = try await service.query("""
            SELECT CONCAT(ROUTINE_NAME, ' ', DATABASE_COLLATION) AS c FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '\(database)' ORDER BY 1
            """).compactMap { $0.column("c")?.string }
        XCTAssertEqual(routines, ["f_len utf8mb4_unicode_ci", "p_latin latin1_swedish_ci"])
        let length = try? await service.query("SELECT `\(database)`.f_len('😀ü') AS n").first?.column("n")?.int
        XCTAssertEqual(length, 2)
    }

    /// A file of several databases (`mysqldump --databases a b`) can't go
    /// into one: each database's DROP TABLE would replace the same-named
    /// table restored from the one before. The restore stops where the
    /// second database starts, before running any of it, even when told to
    /// carry on past failed statements.
    func testStopsWhereTheFileMovesOnToAnotherDatabase() async throws {
        let second = "\(other)_b"
        addTeardownBlock { [service] in _ = try? await service?.rawQuery("DROP DATABASE IF EXISTS `\(second)`") }
        let viewModel = try await restore(Data("""
            CREATE DATABASE /*!32312 IF NOT EXISTS*/ `\(other)` /*!40100 DEFAULT CHARACTER SET latin1 COLLATE latin1_general_ci */;
            USE `\(other)`;
            DROP TABLE IF EXISTS `t`;
            CREATE TABLE `t` (id INT PRIMARY KEY);
            INSERT INTO `t` VALUES (1),(2);
            CREATE DATABASE /*!32312 IF NOT EXISTS*/ `\(second)` /*!40100 DEFAULT CHARACTER SET utf8mb4 */;
            USE `\(second)`;
            DROP TABLE IF EXISTS `t`;
            CREATE TABLE `t` (id INT PRIMARY KEY);
            INSERT INTO `t` VALUES (3);
            """.utf8)) { $0.stopOnFirstError = false }

        XCTAssertEqual(viewModel.failure, .moreThanOneDatabase(line: 6))
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1, 2])
        let collation = try await service.query("""
            SELECT DEFAULT_COLLATION_NAME AS c FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '\(database)'
            """).first?.column("c")?.string
        XCTAssertEqual(collation, "latin1_general_ci")
    }

    func testTurnsTheFilesDatabaseStatementsToTheChosenDatabase() {
        // They pick or replace a database: skipped.
        for statement in ["USE `x`", "use x", "CREATE DATABASE x", "create schema if not exists x", "CREATE OR REPLACE DATABASE x",
                          "DROP DATABASE IF EXISTS x", "/*!40000 DROP DATABASE IF EXISTS `x`*/", "CREATE DATABASE /*!32312 IF NOT EXISTS*/ `x`"] {
            XCTAssertNil(DatabaseRestoreViewModel.intoChosenDatabase(statement), statement)
        }
        // Their settings: given to the current database, the chosen one.
        for (statement, rewritten) in [
            ("CREATE DATABASE /*!32312 IF NOT EXISTS*/ `x` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci */ /*!80016 DEFAULT ENCRYPTION='N' */",
             "ALTER DATABASE /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci */ /*!80016 DEFAULT ENCRYPTION='N' */"),
            ("CREATE OR REPLACE SCHEMA IF NOT EXISTS `a``b` CHARSET latin1", "ALTER DATABASE CHARSET latin1"),
            ("ALTER DATABASE `x` CHARACTER SET latin1 COLLATE latin1_swedish_ci", "ALTER DATABASE CHARACTER SET latin1 COLLATE latin1_swedish_ci"),
            ("alter schema x\ncollate utf8mb4_bin", "ALTER DATABASE collate utf8mb4_bin"),
        ] {
            XCTAssertEqual(DatabaseRestoreViewModel.intoChosenDatabase(statement), rewritten, statement)
        }
        // One database, however its name is quoted.
        XCTAssertEqual(["USE `shop`", "use shop", "CREATE DATABASE /*!32312 IF NOT EXISTS*/ `shop` /*!40100 DEFAULT CHARACTER SET latin1 */",
                        "ALTER DATABASE \"shop\" COLLATE latin1_bin", "/*!40000 DROP DATABASE IF EXISTS `shop`*/"].map(DatabaseRestoreViewModel.databaseName),
                       ["shop", "shop", "shop", "shop", "shop"])
        XCTAssertEqual(DatabaseRestoreViewModel.databaseName(in: "USE `a``b`"), "a`b")
        XCTAssertNil(DatabaseRestoreViewModel.databaseName(in: "ALTER DATABASE COLLATE latin1_bin"))
        // Anything else, a nameless ALTER DATABASE included: as it is.
        for statement in ["USER_LOCK()", "UPDATE t SET a = 1", "CREATE TABLE databases (id INT)", "SELECT 'USE x'", "/*!40101 SET NAMES utf8mb4 */",
                          "ALTER TABLE databases ADD c INT", "ALTER DATABASE COLLATE utf8mb4_unicode_ci", "ALTER DATABASE /*!40100 DEFAULT CHARACTER SET latin1 */"] {
            XCTAssertEqual(DatabaseRestoreViewModel.intoChosenDatabase(statement), statement)
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

    // MARK: - With the mysql client

    /// With "Use the database named in the file" on, the only way the
    /// client restores, starting in the chosen database.
    private func restoreWithTheMysqlClient(_ contents: Data, configure: (DatabaseRestoreViewModel) -> Void = { _ in }) async throws -> DatabaseRestoreViewModel {
        guard ExternalTool.locate(.client, configuredPath: "", preferMariaDB: true) != nil else {
            throw XCTSkip("No mysql or mariadb client is installed.")
        }
        let viewModel = try await restore(contents) {
            $0.usesExternalTool = true
            $0.useDatabaseNamedInFile = true
            configure($0)
        }
        XCTAssertNotNil(viewModel.externalToolURL, "the client must have run, not the built-in engine")
        return viewModel
    }

    /// The client runs the file as it is, its USE included, and where its
    /// split and the app's differ it ran one the app meant to skip: it can't
    /// keep a file out of the database the file was made from. So it's
    /// refused unless the file decides, before anything runs.
    func testMysqlClientIsRefusedUnlessTheFileDecidesTheDatabase() async throws {
        let sheet = DatabaseRestoreViewModel(service: service, database: DatabaseInfo(name: database))
        sheet.useDatabaseNamedInFile = true
        sheet.usesExternalTool = true
        sheet.useDatabaseNamedInFile = false
        XCTAssertFalse(sheet.usesExternalTool, "turning the option off turns the client off")

        _ = try await service.rawQuery("CREATE DATABASE `\(other)`")
        _ = try await service.rawQuery("CREATE TABLE `\(other)`.t (id INT PRIMARY KEY)")
        _ = try await service.rawQuery("INSERT INTO `\(other)`.t VALUES (1)")
        let viewModel = try await restore(Data("""
            USE `\(other)`;
            DROP TABLE IF EXISTS t;
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (2);
            """.utf8)) { $0.usesExternalTool = true }

        XCTAssertTrue(viewModel.errorMessage?.contains("\"Use the database named in the file\"") ?? false, viewModel.errorMessage ?? "nil")
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        let original = try await service.query("SELECT id FROM `\(other)`.t").compactMap { $0.column("id")?.int }
        XCTAssertEqual(original, [1], "the file's own database must be left alone")
        let tables = try await service.query("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '\(database)'")
        XCTAssertTrue(tables.isEmpty, "nothing may run in the chosen one either")
    }

    /// The client follows the file's own database statements, and its error
    /// still names the file's line.
    func testMysqlClientFollowsTheFilesOwnDatabaseAndKeepsItsLines() async throws {
        let viewModel = try await restoreWithTheMysqlClient(Data("""
            /*!40000 DROP DATABASE IF EXISTS `\(other)`*/;
            CREATE DATABASE IF NOT EXISTS `\(other)`
              CHARACTER SET utf8mb4;
            use `\(other)`;
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (7);
            INSERT INTO t VALUES (7);
            INSERT INTO t VALUES (8);
            """.utf8))

        XCTAssertTrue(viewModel.errorMessage?.contains("at line 7") ?? false, viewModel.errorMessage ?? "nil")
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        let restored = try await service.query("SELECT id FROM `\(other)`.t").compactMap { $0.column("id")?.int }
        XCTAssertEqual(restored, [7], "nothing after the failed statement may run")
        let tables = try await service.query("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '\(database)'")
        XCTAssertTrue(tables.isEmpty, "the file moved on from the chosen database")
    }

    /// The client stops at the error while megabytes of the file are still
    /// on their way to it: the restore must say so, not crash on the closed
    /// pipe or pass for finished.
    func testMysqlClientStopsAtTheFirstFailedStatementWhileTheFileIsStillBeingSent() async throws {
        var lines = ["CREATE TABLE t (id INT PRIMARY KEY);", "INSERT INTO t VALUES (1);", "INSERT INTO t VALUES (1);"]
        lines += (2...200_000).map { "INSERT INTO t VALUES (\($0));" }
        let viewModel = try await restoreWithTheMysqlClient(Data(lines.joined(separator: "\n").utf8))

        XCTAssertTrue(viewModel.errorMessage?.contains("at line 3") ?? false, viewModel.errorMessage ?? "nil")
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1])
    }

    /// With --force the client carries on and still exits with 0, so its
    /// errors have to be read from what it says. MariaDB's client also writes
    /// out each failed statement unless told not to: one of over 100 lines
    /// left no room for the errors.
    func testMysqlClientCarriesOnPastFailedStatementsAndReportsThem() async throws {
        let wide = "CREATE TABLE t (\n" + (1...100).map { "  c\($0) INT,\n" }.joined() + "  id INT PRIMARY KEY\n);"
        let viewModel = try await restoreWithTheMysqlClient(Data("""
            CREATE TABLE t (id INT PRIMARY KEY);
            \(wide)
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (2);
            """.utf8)) { $0.stopOnFirstError = false }

        XCTAssertTrue(viewModel.errorMessage?.contains("already exists") ?? false, viewModel.errorMessage ?? "nil")
        XCTAssertTrue(viewModel.errorMessage?.contains("Duplicate entry") ?? false, viewModel.errorMessage ?? "nil")
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1, 2])
    }

    /// Carrying on, the client doesn't reconnect once its connection drops:
    /// every statement after fails, it still ends with exit status 0, and
    /// the sheet said it had restored every other statement.
    func testMysqlClientReportsADroppedConnectionWhenCarryingOn() async throws {
        let viewModel = try await restoreWithTheMysqlClient(Data("""
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (1);
            SET @kill = CONCAT('KILL ', CONNECTION_ID());
            PREPARE kill_itself FROM @kill;
            EXECUTE kill_itself;
            INSERT INTO t VALUES (2);
            INSERT INTO t VALUES (3);
            """.utf8)) { $0.stopOnFirstError = false }

        XCTAssertEqual(viewModel.failure, .connectionLost(line: 6), viewModel.errorMessage ?? "nil")
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1])
    }

    /// Only the first 100 lines the client writes are kept: past that, the
    /// sheet says how many statements failed.
    func testMysqlClientCountsEveryFailedStatement() async throws {
        let lines = ["CREATE TABLE t (id INT PRIMARY KEY);", "INSERT INTO t VALUES (1);"]
            + Array(repeating: "INSERT INTO t VALUES (1);", count: 150) + ["INSERT INTO t VALUES (2);"]
        let viewModel = try await restoreWithTheMysqlClient(Data(lines.joined(separator: "\n").utf8)) { $0.stopOnFirstError = false }

        XCTAssertTrue(viewModel.errorMessage?.contains("150 failed statements") ?? false, viewModel.errorMessage ?? "nil")
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1, 2])
    }

    /// The client drops a byte order mark only from the first line it reads,
    /// which is the first question's: the file's own reached the server in
    /// front of its first statement.
    func testMysqlClientRestoresAFileThatStartsWithAByteOrderMark() async throws {
        let viewModel = try await restoreWithTheMysqlClient(
            Data([0xEF, 0xBB, 0xBF]) + Data("CREATE TABLE t (id INT PRIMARY KEY);\nINSERT INTO t VALUES (1);\n".utf8))

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.didFinishSuccessfully)
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1])
    }

    /// The client's own errors (a DELIMITER without a delimiter) have no
    /// code; their line is the file's too.
    func testTheClientsErrorsNameTheFilesLine() {
        let messages = "ERROR 1062 (23000) at line 5: Duplicate entry\nERROR at line 9: DELIMITER must be followed by a 'delimiter' character or string"
        XCTAssertEqual(DatabaseRestoreViewModel.fileLines(in: messages, questionLines: [1, 4]),
                       "ERROR 1062 (23000) at line 1: Duplicate entry\nERROR at line 5: DELIMITER must be followed by a 'delimiter' character or string")
    }

    /// What the built-in restore refuses as not UTF-8 (a mysqldump file made
    /// without --hex-blob), and a line break written raw inside a string:
    /// the client must store exactly these bytes.
    func testMysqlClientRestoresRawBytesExactly() async throws {
        var contents = Data("CREATE TABLE t (id INT PRIMARY KEY, b BLOB, txt TEXT);\nINSERT INTO t VALUES (1, _binary '".utf8)
        contents.append(contentsOf: [0xFF, 0xFE, 0x5C, 0x30, 0xC3])  // \0 escaped, as mysqldump writes it
        contents.append(Data("', 'line\r\nbreak');\n".utf8))
        let viewModel = try await restoreWithTheMysqlClient(contents)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.didFinishSuccessfully)
        let row = try await service.textQuery("SELECT HEX(b) AS b, HEX(txt) AS txt FROM `\(database)`.t").first
        XCTAssertEqual(row?.column("b")?.string, "FFFE00C3")
        XCTAssertEqual(row?.column("txt")?.string, "6C696E650D0A627265616B")
    }

    /// A trigger made under NO_BACKSLASH_ESCAPES ends a string with a
    /// backslash ('\'), which the client, told the mode by the server, reads
    /// as the whole string. The file is split the same way, so what follows
    /// reaches the client as the statements it is. The error at the end
    /// still names the file's line, although the client was asked for the
    /// mode four times, on lines of their own.
    func testMysqlClientReadsBackslashesTheWayItsSessionsSQLModeSays() async throws {
        let viewModel = try await restoreWithTheMysqlClient(Data(#"""
            CREATE TABLE t (id INT PRIMARY KEY, path VARCHAR(20));
            /*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
            /*!50003 SET sql_mode              = 'NO_BACKSLASH_ESCAPES' */ ;
            DELIMITER ;;
            /*!50003 CREATE*/ /*!50017 DEFINER=CURRENT_USER*/ /*!50003 TRIGGER t_bi BEFORE INSERT ON t FOR EACH ROW SET NEW.path = REPLACE(NEW.path, '\', '/') */;;
            DELIMITER ;
            /*!50003 SET sql_mode              = @saved_sql_mode */ ;
            INSERT INTO t VALUES (1, 'it''s');
            INSERT INTO t VALUES (1, 'again');
            """#.utf8)) { $0.readChunkSize = 7 }

        XCTAssertTrue(viewModel.errorMessage?.contains("at line 9: Duplicate entry") ?? false, viewModel.errorMessage ?? "nil")
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1])
    }

    /// A trigger as HeidiSQL exports it, with Windows line breaks: the client
    /// read the file's `DELIMITER ;` as ";\r", the scan as ";", so the
    /// question after the next statement never ended for the client, and
    /// the restore waited for its answer forever.
    func testMysqlClientRestoresATriggerWithWindowsLineBreaks() async throws {
        let viewModel = try await restoreWithTheMysqlClient(Data("""
            CREATE TABLE t (id INT PRIMARY KEY);
            SET @OLDTMP_SQL_MODE=@@SQL_MODE, SQL_MODE='STRICT_TRANS_TABLES';
            DELIMITER //
            CREATE TRIGGER t_bi BEFORE INSERT ON t FOR EACH ROW BEGIN
            \tSET NEW.id = NEW.id + 1;
            END//
            DELIMITER ;
            SET SQL_MODE=@OLDTMP_SQL_MODE;
            INSERT INTO t VALUES (1);

            """.replacingOccurrences(of: "\n", with: "\r\n").utf8))

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.didFinishSuccessfully)
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [2], "the trigger must have run")
    }

    /// The last statement has no delimiter and mentions sql_mode: the
    /// question went to the client while that statement was still open, and
    /// carrying on past errors, the restore waited for an answer that never
    /// came.
    func testMysqlClientRestoresAFileEndingInAStatementWithoutADelimiter() async throws {
        let viewModel = try await restoreWithTheMysqlClient(Data("""
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (1);
            SET SESSION sql_mode = 'STRICT_TRANS_TABLES'
            """.utf8)) { $0.stopOnFirstError = false }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.didFinishSuccessfully)
        let restored = try await ids(in: "t")
        XCTAssertEqual(restored, [1])
    }
}
