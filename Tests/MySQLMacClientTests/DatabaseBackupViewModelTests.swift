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
        try await service.disconnect()
    }

    private func makeViewModel() -> DatabaseBackupViewModel {
        DatabaseBackupViewModel(service: service, database: DatabaseInfo(name: "mysqlmacclient_test"))
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
        XCTAssertTrue(contents.contains("INSERT INTO `mysqlmacclient_test`.`widgets`"))
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
        XCTAssertTrue(contents.contains("DROP TABLE IF EXISTS `mysqlmacclient_test`.`widgets`;"))
        XCTAssertTrue(contents.contains("DROP VIEW IF EXISTS `mysqlmacclient_test`.`widget_view`;"))
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
        XCTAssertTrue(contents.contains("DROP PROCEDURE IF EXISTS `mysqlmacclient_test`.`backup_test_proc`;"))
        XCTAssertTrue(contents.contains("DROP FUNCTION IF EXISTS `mysqlmacclient_test`.`backup_test_fn`;"))
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
