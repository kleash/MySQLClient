import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP) — same convention as
/// `TableExportViewModelTests`. Uses the `widgets`/`widget_view` fixtures.
///
/// Routine (procedure/function) creation and even plain `SHOW PROCEDURE/
/// FUNCTION STATUS` reads are broken on this project's own local test
/// server (`mysql.proc` from MariaDB 10.1 under a 10.4 binary — see
/// `local_test_db_state` memory; `mariadb-upgrade` is the fix but hasn't
/// been run). Tests whose whole point is verifying routine-dump behavior
/// call `skipIfRoutineCatalogUnavailable()` and skip themselves rather
/// than fail for an environment reason that has nothing to do with this
/// feature's own correctness.
@MainActor
final class DatabaseBackupViewModelTests: XCTestCase {
    var service: MySQLService!
    var tempFileURL: URL!
    /// Made by `makeScratchDatabase`, dropped in tearDown.
    private var scratchDatabases: [String] = []

    override func setUp() async throws {
        // Assigned before any throwing call — see TableExportViewModelTests
        // for why (a thrown `connect()` must not leave `tearDown` force-
        // unwrapping a never-set `URL!`).
        tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sql")
        service = MySQLService()
        try await service.connect(
            host: TestDatabase.host,
            port: TestDatabase.port,
            username: TestDatabase.username,
            password: TestDatabase.password,
            database: "mysqlmacclient_test"
        )
        try await service.execute("DELETE FROM widgets")
        try await service.execute("ALTER TABLE widgets AUTO_INCREMENT = 1")
        try await service.execute("""
            INSERT INTO widgets (name, quantity, created_at, notes) VALUES
            ('Bolt', 100, '2024-01-15 10:30:00', 'Standard bolt'),
            ('Nut', 250, '2024-02-20 14:00:00', NULL),
            ('Washer', NULL, NULL, 'Out of stock')
            """)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempFileURL)
        // Best-effort: harmless if these were never created (routine
        // catalog unavailable) or already dropped.
        _ = try? await service.rawQuery("DROP PROCEDURE IF EXISTS backup_test_proc")
        _ = try? await service.rawQuery("DROP FUNCTION IF EXISTS backup_test_fn")
        for name in scratchDatabases {
            _ = try? await service.rawQuery("DROP DATABASE IF EXISTS `\(name)`")
        }
        _ = try? await service.rawQuery("DROP USER IF EXISTS 'mysqlmacclient_noevent'@'%'")
        try await service.disconnect()
    }

    private func makeViewModel() -> DatabaseBackupViewModel {
        DatabaseBackupViewModel(service: service, database: DatabaseInfo(name: "mysqlmacclient_test"))
    }

    /// A database of the test's own, with `statements` run in it.
    private func makeScratchDatabase(_ name: String, _ statements: [String]) async throws -> DatabaseInfo {
        scratchDatabases.append(name)
        _ = try await service.rawQuery("DROP DATABASE IF EXISTS `\(name)`")
        _ = try await service.rawQuery("CREATE DATABASE `\(name)`")
        _ = try await service.rawQuery("USE `\(name)`")
        for statement in statements {
            _ = try await service.rawQuery(statement)
        }
        _ = try await service.rawQuery("USE mysqlmacclient_test")
        return DatabaseInfo(name: name)
    }

    private func connectAnother() async throws -> MySQLService {
        let other = MySQLService()
        try await other.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username, password: TestDatabase.password, database: nil)
        return other
    }

    /// `throws` so callers can `try await` it directly before the rest of
    /// the test; throws `XCTSkip` — never fails — when the routine catalog
    /// itself can't even be listed, since creating a routine can't succeed
    /// either in that case.
    private func createScratchRoutinesOrSkip() async throws {
        guard (try? await service.rawQuery("SHOW PROCEDURE STATUS WHERE Db = 'mysqlmacclient_test'")) != nil else {
            throw XCTSkip("Sunucunun mysql.proc tablosu güncel değil (mariadb-upgrade gerekiyor) — routine testi atlandı.")
        }
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS backup_test_proc")
        _ = try await service.rawQuery("DROP FUNCTION IF EXISTS backup_test_fn")
        _ = try await service.rawQuery("""
            CREATE PROCEDURE backup_test_proc()
            BEGIN
                SELECT 1;
            END
            """)
        _ = try await service.rawQuery("""
            CREATE FUNCTION backup_test_fn(p INT) RETURNS INT DETERMINISTIC
            BEGIN
                RETURN p * 2;
            END
            """)
    }

    // MARK: - Loading / selection

    func testLoadObjectsPopulatesTablesAndViews() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()

        XCTAssertTrue(viewModel.allTables.contains { $0.name == "widgets" })
        XCTAssertTrue(viewModel.allViews.contains { $0.name == "widget_view" })
        XCTAssertEqual(viewModel.selectedTables, Set(viewModel.allTables))
        XCTAssertEqual(viewModel.selectedViews, Set(viewModel.allViews))
    }

    func testLoadObjectsPopulatesRoutineCategoriesWhenAvailable() async throws {
        try await createScratchRoutinesOrSkip()
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.allProcedures.contains { $0.name == "backup_test_proc" })
        XCTAssertTrue(viewModel.allFunctions.contains { $0.name == "backup_test_fn" })
        XCTAssertEqual(viewModel.selectedProcedures, Set(viewModel.allProcedures))
        XCTAssertEqual(viewModel.selectedFunctions, Set(viewModel.allFunctions))
    }

    /// The robustness behavior this environment's own broken server proves
    /// end-to-end: an unreadable routine catalog degrades to two empty
    /// categories plus a note, not a blanket failure that also loses the
    /// tables/views that loaded just fine.
    func testLoadObjectsDegradesGracefullyWhenRoutineCatalogIsUnavailable() async throws {
        guard (try? await service.rawQuery("SHOW PROCEDURE STATUS WHERE Db = 'mysqlmacclient_test'")) == nil else {
            throw XCTSkip("Bu ortamda routine kataloğu erişilebilir — bozuk-katalog davranışını tetikleyemiyoruz.")
        }
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()

        XCTAssertTrue(viewModel.allTables.contains { $0.name == "widgets" }, "routine listesi başarısız olsa da tablolar yüklenmeli")
        XCTAssertEqual(viewModel.allProcedures, [])
        XCTAssertEqual(viewModel.allFunctions, [])
        XCTAssertNotNil(viewModel.loadWarning, "engellemeyen bir uyarı olarak raporlanmalı")
        XCTAssertNil(viewModel.errorMessage, "yükleme uyarısı, çalıştırma hatasıyla karıştırılmamalı")
    }

    /// Listing events takes the EVENT privilege, which a user who can read
    /// everything else may lack: they still get every trigger.
    func testLoadObjectsListsTriggersForAUserWhoCantListEvents() async throws {
        let scratch = try await makeScratchDatabase("mysqlmacclient_backup_noevent", [
            "CREATE TABLE t (id INT PRIMARY KEY)",
            "CREATE TRIGGER t_bi BEFORE INSERT ON t FOR EACH ROW SET NEW.id = NEW.id",
        ])
        _ = try await service.rawQuery("DROP USER IF EXISTS 'mysqlmacclient_noevent'@'%'")
        _ = try await service.rawQuery("CREATE USER 'mysqlmacclient_noevent'@'%' IDENTIFIED BY 'no-event'")
        _ = try await service.rawQuery("GRANT SELECT, SHOW VIEW, TRIGGER ON `mysqlmacclient_backup_noevent`.* TO 'mysqlmacclient_noevent'@'%'")
        let restricted = MySQLService()
        try await restricted.connect(host: TestDatabase.host, port: TestDatabase.port, username: "mysqlmacclient_noevent", password: "no-event", database: nil)

        let viewModel = DatabaseBackupViewModel(service: restricted, database: scratch)
        await viewModel.loadDatabasesAndObjects()
        try await restricted.disconnect()

        XCTAssertEqual(viewModel.allTriggers.map(\.name), ["t_bi"])
        XCTAssertEqual(viewModel.selectedTriggers.map(\.name), ["t_bi"])
        XCTAssertNotNil(viewModel.loadWarning, "the events that couldn't be listed")
    }

    /// A single transaction reads only InnoDB tables from one snapshot: the
    /// dialog names the others (`widgets` is Aria).
    func testLoadObjectsNamesTablesASingleTransactionCantSnapshot() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()

        let warning = try XCTUnwrap(viewModel.loadWarning)
        XCTAssertTrue(warning.contains("widgets"))
        XCTAssertFalse(warning.contains("tags"), "an InnoDB table")
    }

    func testSelectNoneThenSelectAllRestoresFullSelection() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()

        viewModel.selectNoObjects()
        XCTAssertEqual(viewModel.selectedObjectCount, 0)

        viewModel.selectAllObjects()
        let total = viewModel.allTables.count + viewModel.allViews.count + viewModel.allProcedures.count + viewModel.allFunctions.count
        XCTAssertEqual(viewModel.selectedObjectCount, total)
    }

    func testSelectDatabaseReloadsObjectsAndUpdatesDefaultFilename() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        let originalFileName = viewModel.outputFileURL?.lastPathComponent

        await viewModel.selectDatabase(DatabaseInfo(name: "information_schema"))

        XCTAssertFalse(viewModel.allTables.contains { $0.name == "widgets" }, "information_schema tablo listesi farklı olmalı")
        XCTAssertNotEqual(viewModel.outputFileURL?.lastPathComponent, originalFileName)
        XCTAssertEqual(viewModel.outputFileURL?.lastPathComponent, "information_schema.sql")
    }

    func testLockTablesAndSingleTransactionOptionsAreMutuallyExclusive() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()

        viewModel.options.source.lockTablesForReading = true
        XCTAssertFalse(viewModel.options.source.useSingleTransaction)

        viewModel.options.source.useSingleTransaction = true
        XCTAssertFalse(viewModel.options.source.lockTablesForReading, "tek işlem açılınca kilitleme kapanmalı")
    }

    // MARK: - Running the backup

    func testRunBackupStructureAndDataWritesCreateAndInsertsForTablesAndViews() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("CREATE TABLE IF NOT EXISTS `widgets`"))
        XCTAssertTrue(contents.contains("INSERT INTO `widgets`"))
        XCTAssertTrue(contents.contains("CREATE OR REPLACE"))
        XCTAssertTrue(contents.contains("VIEW `widget_view`"))
        XCTAssertTrue(viewModel.didFinishSuccessfully, "başarılı bir yedekleme tamamlanma uyarısını tetiklemeli")
    }

    func testRunBackupIncludesRoutinesWhenCatalogIsAvailable() async throws {
        try await createScratchRoutinesOrSkip()
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("DELIMITER $$"))
        XCTAssertTrue(contents.contains("PROCEDURE `backup_test_proc`"))
        XCTAssertTrue(contents.contains("FUNCTION `backup_test_fn`"))
    }

    func testRunBackupStructureOnlyOmitsInsertStatements() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        viewModel.options.mode = .structureOnly

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("CREATE TABLE IF NOT EXISTS `widgets`"))
        XCTAssertFalse(contents.contains("INSERT INTO"))
    }

    func testRunBackupDataOnlyOmitsCreateAndViewsEntirely() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        viewModel.options.mode = .dataOnly

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("INSERT INTO"))
        XCTAssertFalse(contents.contains("CREATE TABLE"))
        XCTAssertFalse(contents.contains("VIEW `widget_view`"))
    }

    func testRunBackupWithExtendedInsertsProducesMultiRowValuesClause() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        viewModel.selectedViews = []

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("), ("), "3 satırlık widgets tek bir çok-satırlı INSERT'e sığmalı")
    }

    func testRunBackupWithDropStatementsOptionEmitsDropBeforeCreateForTablesAndViews() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        viewModel.options.file.includeDropStatements = true

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("DROP TABLE IF EXISTS `widgets`;"))
        XCTAssertTrue(contents.contains("DROP VIEW IF EXISTS `widget_view`;"))
    }

    func testRunBackupWithDropStatementsOptionEmitsDropForRoutinesWhenAvailable() async throws {
        try await createScratchRoutinesOrSkip()
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        viewModel.options.file.includeDropStatements = true

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("DROP PROCEDURE IF EXISTS `backup_test_proc`;"))
        XCTAssertTrue(contents.contains("DROP FUNCTION IF EXISTS `backup_test_fn`;"))
    }

    func testForeignKeyChecksOptionEmitsBothSetStatementsWhenEnabled() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("SET FOREIGN_KEY_CHECKS=0;"))
        XCTAssertTrue(contents.contains("SET FOREIGN_KEY_CHECKS=1;"))
    }

    /// Table data is fetched a page at a time (`dataPageSize`, 1000 rows) —
    /// a table larger than one page must still come out complete, with no
    /// row dropped or duplicated at the page boundary. This is the
    /// regression guard for the crash a real multi-million-row table hit:
    /// one un-LIMITed `SELECT *` exhausting memory and dropping the
    /// connection mid-read.
    func testRunBackupPagesThroughATableLargerThanOnePageWithoutLosingRows() async throws {
        // 250 rows over a 100-row page spans three pages (100 + 100 + 50).
        try await service.execute("DELETE FROM widgets")
        try await service.execute("ALTER TABLE widgets AUTO_INCREMENT = 1")
        for batch in 0..<3 {
            let upper = batch == 2 ? 50 : 100
            let values = (0..<upper)
                .map { "('Row \(batch * 100 + $0)', \(batch * 100 + $0), NULL, NULL)" }
                .joined(separator: ", ")
            try await service.execute("INSERT INTO widgets (name, quantity, created_at, notes) VALUES \(values)")
        }

        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.dataPageSize = 100
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        // Only `widgets` — the other fixture tables carry a row each, which
        // would otherwise be counted in the INSERT total below.
        viewModel.selectedTables = Set(viewModel.allTables.filter { $0.name == "widgets" })
        viewModel.selectedViews = []
        viewModel.options.mode = .dataOnly
        viewModel.options.file.useExtendedInserts = false // one INSERT per row, so they're countable

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        let insertCount = contents.components(separatedBy: "INSERT INTO").count - 1
        XCTAssertEqual(insertCount, 250, "her satır tam olarak bir kez yazılmalı")
        // Spot-check a row from each page, including both boundaries.
        XCTAssertTrue(contents.contains("'Row 0'"))
        XCTAssertTrue(contents.contains("'Row 99'"))
        XCTAssertTrue(contents.contains("'Row 100'"))
        XCTAssertTrue(contents.contains("'Row 199'"))
        XCTAssertTrue(contents.contains("'Row 200'"))
        XCTAssertTrue(contents.contains("'Row 249'"))
    }

    /// The no-primary-key fallback path: `widget_logs_nopk` can't be paged
    /// by key range, so it uses `OFFSET`. Still has to come out complete
    /// across a page boundary.
    func testRunBackupPagesATableWithoutAPrimaryKeyAcrossPageBoundary() async throws {
        try await service.execute("DELETE FROM widget_logs_nopk")
        for batch in 0..<3 {
            let upper = batch == 2 ? 50 : 100
            let values = (0..<upper)
                .map { "(\(batch * 100 + $0), 'msg \(batch * 100 + $0)', NULL)" }
                .joined(separator: ", ")
            try await service.execute("INSERT INTO widget_logs_nopk (widget_id, message, logged_at) VALUES \(values)")
        }

        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.dataPageSize = 100
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        viewModel.selectedTables = Set(viewModel.allTables.filter { $0.name == "widget_logs_nopk" })
        viewModel.selectedViews = []
        viewModel.options.mode = .dataOnly
        viewModel.options.file.useExtendedInserts = false

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        let insertCount = contents.components(separatedBy: "INSERT INTO").count - 1
        XCTAssertEqual(insertCount, 250, "PK'sız tabloda da her satır tam olarak bir kez yazılmalı")
        XCTAssertTrue(contents.contains("'msg 99'"))
        XCTAssertTrue(contents.contains("'msg 100'"))

        try await service.execute("DELETE FROM widget_logs_nopk")
    }

    /// Regression guard: the percentage used to be object-count based, so a
    /// single large table left it pinned at 0% for the entire run and then
    /// jumped to 100%. It must move *within* one table now.
    func testProgressPercentageAdvancesWithinASingleLargeTable() async throws {
        try await service.execute("DELETE FROM widgets")
        try await service.execute("ALTER TABLE widgets AUTO_INCREMENT = 1")
        for batch in 0..<3 {
            let values = (0..<100)
                .map { "('Row \(batch * 100 + $0)', \(batch * 100 + $0), NULL, NULL)" }
                .joined(separator: ", ")
            try await service.execute("INSERT INTO widgets (name, quantity, created_at, notes) VALUES \(values)")
        }

        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        // Several pages, so there are intermediate progress updates to see.
        viewModel.dataPageSize = 50
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        // Exactly one object, so any movement in the percentage can only
        // come from row-level progress inside it.
        viewModel.selectedTables = Set(viewModel.allTables.filter { $0.name == "widgets" })
        viewModel.selectedViews = []
        viewModel.selectedProcedures = []
        viewModel.selectedFunctions = []
        viewModel.options.mode = .dataOnly

        var midRunPercentages: [Double] = []
        viewModel.startBackup()
        while viewModel.isRunning {
            if let progress = viewModel.progress, progress.percentage > 0, progress.percentage < 1 {
                midRunPercentages.append(progress.percentage)
            }
            await Task.yield()
        }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(
            midRunPercentages.isEmpty,
            "tek tablo işlenirken yüzde 0 ile 100 arasında en az bir kez ilerlemeli"
        )
        XCTAssertEqual(viewModel.progress?.percentage, 1.0, "bitişte %100 olmalı")
    }

    func testCancelBackupMidRunStopsAndDeletesThePartialFile() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        viewModel.interObjectDelay = .milliseconds(200)

        viewModel.startBackup()
        while viewModel.progress == nil { await Task.yield() }
        viewModel.cancelBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path))
        XCTAssertFalse(viewModel.didFinishSuccessfully, "iptal edilen bir yedekleme tamamlanma uyarısını tetiklememeli")
    }

    /// Locking tables, a trigger whose table isn't backed up is still read:
    /// its definition doesn't need the table locked.
    func testLockingTablesBacksUpATriggerWithoutItsTable() async throws {
        let scratch = try await makeScratchDatabase("mysqlmacclient_backup_locktrigger", [
            "CREATE TABLE t (id INT PRIMARY KEY)",
            "CREATE TABLE u (id INT PRIMARY KEY)",
            "CREATE TRIGGER t_bi BEFORE INSERT ON t FOR EACH ROW SET NEW.id = NEW.id",
        ])
        let viewModel = DatabaseBackupViewModel(service: service, database: scratch)
        await viewModel.loadDatabasesAndObjects()
        viewModel.selectedTables = Set(viewModel.allTables.filter { $0.name == "u" })
        viewModel.options.source.lockTablesForReading = true
        viewModel.outputFileURL = tempFileURL
        viewModel.outputLocationIsGranted = true

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(try String(contentsOf: tempFileURL, encoding: .utf8).contains("TRIGGER `t_bi`"))
    }

    /// Cancelled before it has counted every table's rows, the backup stops
    /// counting: on a big database each COUNT(*) reads a whole table on the
    /// server.
    func testCancelBackupStopsCountingRows() async throws {
        let scratch = try await makeScratchDatabase("mysqlmacclient_backup_cancel", (1...40).map { "CREATE TABLE t\($0) (id INT PRIMARY KEY)" })
        let viewModel = DatabaseBackupViewModel(service: service, database: scratch)
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        viewModel.outputLocationIsGranted = true
        func selectsSoFar() async throws -> Int {
            let rows = try await service.textQuery("SHOW GLOBAL STATUS LIKE 'Com_select'")
            return Int(rows.first?.column("Value")?.string ?? "") ?? 0
        }
        let before = try await selectsSoFar()

        viewModel.startBackup()
        viewModel.cancelBackup()
        while viewModel.isRunning { await Task.yield() }

        let selects = try await selectsSoFar() - before
        XCTAssertLessThan(selects, 20, "SELECTs the server ran for a cancelled backup of 40 tables")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path))
    }

    /// The regression guard for the data-loss bug this app's own
    /// `AtomicFileWriter` fixed: a backup cancelled mid-run must not touch
    /// whatever was already sitting at `outputFileURL` — e.g. yesterday's
    /// backup, if the user picked the same path to overwrite it.
    func testCancelledBackupLeavesAPreexistingFileAtOutputPathUntouched() async throws {
        try Data("dünkü yedek — bozulmamalı".utf8).write(to: tempFileURL)

        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        // Bypasses the real `NSSavePanel` `startBackup()` would otherwise
        // pop for a never-granted `outputFileURL` — can't run headless.
        viewModel.outputLocationIsGranted = true
        viewModel.interObjectDelay = .milliseconds(200)

        viewModel.startBackup()
        while viewModel.progress == nil { await Task.yield() }
        viewModel.cancelBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertEqual(try String(contentsOf: tempFileURL, encoding: .utf8), "dünkü yedek — bozulmamalı")
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: tempFileURL.deletingLastPathComponent().path)) ?? []
        XCTAssertTrue(siblings.filter { $0.hasPrefix(".\(tempFileURL.lastPathComponent).tmp-") }.isEmpty, "geçici dosya artık kalmamalı")
    }

    /// The server drops the backup's connection part-way through. A new
    /// session would have neither the snapshot nor the settings the backup
    /// reads under, so the backup must fail and save nothing rather than
    /// carry on.
    func testBackupFailsAndSavesNothingWhenItsConnectionDrops() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        viewModel.outputLocationIsGranted = true
        viewModel.interObjectDelay = .milliseconds(300)
        let newest = try await service.query("SELECT MAX(ID) AS id FROM information_schema.PROCESSLIST")
        let newestBefore = try XCTUnwrap(newest.first?.column("id")?.int)

        viewModel.startBackup()
        // Into the pause after the first object.
        while viewModel.progress?.currentObjectDescription.isEmpty ?? true { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        let backupConnection = try await service.query("""
            SELECT ID AS id FROM information_schema.PROCESSLIST
            WHERE ID > \(newestBefore) AND DB = 'mysqlmacclient_test'
            """)
        try await kill(XCTUnwrap(backupConnection.first?.column("id")?.int, "the backup reads on a connection of its own"))
        while viewModel.isRunning { await Task.yield() }

        XCTAssertEqual(viewModel.errorMessage, DatabaseBackupViewModel.BackupError.connectionLost.errorDescription)
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path))
    }

    /// The app's connection dropped while the dialog sat open (a server
    /// with a short wait_timeout). The backup opens one of its own, so it
    /// isn't affected.
    func testBackupRunsAfterTheAppsConnectionDroppedWhileIdle() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        viewModel.outputLocationIsGranted = true
        viewModel.options.mode = .structureOnly
        let idRows = try await service.query("SELECT CONNECTION_ID() AS id")
        try await kill(XCTUnwrap(idRows.first?.column("id")?.int))

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.didFinishSuccessfully)
    }

    /// A transaction the user left open on the app's connection stays
    /// theirs: a backup's START TRANSACTION on that connection would commit
    /// it, and their ROLLBACK would then undo nothing.
    func testBackupLeavesATransactionOpenOnTheAppsConnectionAlone() async throws {
        _ = try await service.rawQuery("START TRANSACTION")
        try await service.execute("INSERT INTO tags (name) VALUES ('not committed')")
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        viewModel.outputLocationIsGranted = true

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }
        _ = try await service.rawQuery("ROLLBACK")

        XCTAssertNil(viewModel.errorMessage)
        let rows = try await service.query("SELECT COUNT(*) AS n FROM tags WHERE name = 'not committed'")
        try await service.execute("DELETE FROM tags WHERE name = 'not committed'")
        XCTAssertEqual(rows.first?.column("n")?.int, 0)
    }

    private func kill(_ connectionID: Int) async throws {
        let killer = try await connectAnother()
        try await killer.execute("KILL \(connectionID)")
        try await killer.disconnect()
    }

    /// A row committed after the backup began isn't in it, even with the
    /// app's connection at READ COMMITTED, where the server ignores WITH
    /// CONSISTENT SNAPSHOT and every read sees the latest commit.
    func testBackupReadsOneSnapshotWhateverTheAppsIsolationLevel() async throws {
        try await service.execute("DELETE FROM widget_logs_nopk")
        _ = try await service.rawQuery("SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED")
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        viewModel.outputLocationIsGranted = true
        viewModel.interObjectDelay = .milliseconds(200)

        viewModel.startBackup()
        // The first table is read, so the snapshot is taken; widget_logs_nopk
        // is read later.
        while (viewModel.progress?.completedObjects ?? 0) < 1 { await Task.yield() }
        let writer = try await connectAnother()
        try await writer.execute("INSERT INTO mysqlmacclient_test.widget_logs_nopk (message) VALUES ('after the snapshot')")
        try await writer.disconnect()
        while viewModel.isRunning { await Task.yield() }
        try await service.execute("DELETE FROM widget_logs_nopk")

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(try String(contentsOf: tempFileURL, encoding: .utf8).contains("after the snapshot"))
    }

    /// Once read, a table is free for DDL again although the backup's
    /// transaction goes on: otherwise an ALTER of it waits for the whole
    /// backup, and every other query on the table queues behind the ALTER.
    func testBackupLetsGoOfEachTableOnceItIsRead() async throws {
        let scratch = try await makeScratchDatabase("mysqlmacclient_backup_mdl", [
            "CREATE TABLE a (id INT PRIMARY KEY) ENGINE=InnoDB",
            "CREATE TABLE b (id INT PRIMARY KEY) ENGINE=InnoDB",
            "INSERT INTO a VALUES (1)",
        ])
        let viewModel = DatabaseBackupViewModel(service: service, database: scratch)
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = tempFileURL
        viewModel.outputLocationIsGranted = true
        viewModel.interObjectDelay = .seconds(2)

        viewModel.startBackup()
        // `a` is read; the backup is on `b` and then pauses.
        while (viewModel.progress?.completedObjects ?? 0) < 1 { await Task.yield() }
        let other = try await connectAnother()
        _ = try await other.rawQuery("SET SESSION lock_wait_timeout = 1")
        var alterError: Error?
        do {
            _ = try await other.rawQuery("ALTER TABLE mysqlmacclient_backup_mdl.a COMMENT = 'altered during the backup'")
        } catch {
            alterError = error
        }
        try await other.disconnect()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNil(alterError)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRunBackupToUnwritablePathSetsErrorMessageInsteadOfCrashing() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadDatabasesAndObjects()
        viewModel.outputFileURL = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.sql")
        viewModel.outputLocationIsGranted = true

        viewModel.startBackup()
        while viewModel.isRunning { await Task.yield() }

        XCTAssertNotNil(viewModel.errorMessage)
    }
}
