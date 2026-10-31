import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP) — same convention as
/// `TableDataViewModelTests`. Uses the `widgets` seed table (Bolt/Nut/
/// Washer), reset in `setUp`.
@MainActor
final class TableExportViewModelTests: XCTestCase {
    var service: MySQLService!
    var tempFileURL: URL!

    override func setUp() async throws {
        // Assigned before any throwing call below — if `connect()` fails
        // (server down), `setUp` aborts partway through but `tearDown`
        // still runs and unconditionally reads `tempFileURL`; leaving it
        // nil until after a throwing step crashed the whole test process
        // with a force-unwrap trap instead of just failing this test.
        tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).export")
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
        try await service.disconnect()
    }

    private func makeViewModel() -> TableExportViewModel {
        TableExportViewModel(service: service, table: TableInfo(database: "mysqlmacclient_test", name: "widgets", isView: false))
    }

    /// Runs a started export to completion — `startExport()` is
    /// fire-and-forget (cancellation needs to be reachable from a
    /// different call site), so tests poll `isExporting` the same way
    /// `DatabaseBackupViewModelTests` polls `isRunning`.
    private func runToCompletion(_ viewModel: TableExportViewModel) async {
        // Bypasses the real `NSSavePanel` `startExport()` would otherwise
        // pop for a never-granted `outputFileURL` — the panel can't run
        // headless in a test process.
        viewModel.outputLocationIsGranted = true
        viewModel.startExport()
        while viewModel.isExporting { await Task.yield() }
    }

    /// Switching the format tab must keep the suggested filename's
    /// extension in sync — otherwise the file written ends up with the
    /// previous format's extension even though its contents are correct
    /// for the newly selected one.
    func testChangingFormatUpdatesOutputFileExtensionButKeepsDirectoryAndStem() async throws {
        let viewModel = makeViewModel()
        let base = URL(fileURLWithPath: "/Users/someone/Desktop/widgets.csv")
        viewModel.outputFileURL = base
        viewModel.options.format = .csv // no-op: same format, must not touch the URL

        XCTAssertEqual(viewModel.outputFileURL, base)

        viewModel.options.format = .sql
        XCTAssertEqual(viewModel.outputFileURL, URL(fileURLWithPath: "/Users/someone/Desktop/widgets.sql"))

        viewModel.options.format = .json
        XCTAssertEqual(viewModel.outputFileURL, URL(fileURLWithPath: "/Users/someone/Desktop/widgets.json"))
    }

    func testLoadColumnsPopulatesAllColumnsAllSelectedByDefault() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.allColumns.map(\.name).sorted(), ["created_at", "id", "name", "notes", "quantity"])
        XCTAssertEqual(viewModel.selectedColumnNames, Set(viewModel.allColumns.map(\.name)))
    }

    func testSelectAllAndDeselectAllToggleTheFullSet() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()

        viewModel.deselectAllColumns()
        XCTAssertTrue(viewModel.selectedColumnNames.isEmpty)

        viewModel.selectAllColumns()
        XCTAssertEqual(viewModel.selectedColumnNames, Set(viewModel.allColumns.map(\.name)))
    }

    // MARK: - Running the export

    /// Proves the "always the entire table" requirement: nothing here
    /// touches a `TableDataViewModel` filter/sort/page — every seed row
    /// still has to land in the file.
    func testRunExportWritesEveryRowForCSV() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        let lines = contents.split(separator: "\r\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 4) // header + 3 seed rows
        XCTAssertTrue(contents.contains("Bolt"))
        XCTAssertTrue(contents.contains("Nut"))
        XCTAssertTrue(contents.contains("Washer"))
        XCTAssertTrue(viewModel.didFinishSuccessfully, "başarılı bir export tamamlanma uyarısını tetiklemeli")
    }

    func testRunExportWritesCreateTableAndInsertsForSQL() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.options.format = .sql
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("CREATE TABLE IF NOT EXISTS `widgets`"))
        XCTAssertEqual(contents.components(separatedBy: "INSERT INTO").count - 1, 3)
        XCTAssertTrue(contents.contains("'Bolt'"))
    }

    /// `widget_view` is a real view over `widgets` (see the fixture schema).
    /// CSV/HTML/JSON already work on a view unmodified — this only pins the
    /// SQL format, since `SHOW CREATE TABLE` on a view silently redirects
    /// to a `Create View` column instead of `Create Table`, which used to
    /// make SQL export throw for every view.
    func testRunExportOnAViewWritesTheViewDefinitionNotInsertsForSQL() async throws {
        let viewModel = TableExportViewModel(service: service, table: TableInfo(database: "mysqlmacclient_test", name: "widget_view", isView: true))
        await viewModel.loadColumns()
        viewModel.options.format = .sql
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("CREATE OR REPLACE"))
        XCTAssertTrue(contents.contains("VIEW `widget_view`"))
        XCTAssertFalse(contents.contains("INSERT INTO"), "a view has no rows of its own to freeze as INSERT statements")
    }

    /// CSV export against a view — confirms the already-working data path
    /// (columns()/SELECT both work unmodified against a view) stays that way.
    func testRunExportOnAViewWritesRowsForCSV() async throws {
        let viewModel = TableExportViewModel(service: service, table: TableInfo(database: "mysqlmacclient_test", name: "widget_view", isView: true))
        await viewModel.loadColumns()
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Bolt"))
        XCTAssertTrue(contents.contains("Nut"))
        XCTAssertTrue(contents.contains("Washer"))
    }

    /// A column-subset export must only emit the checked columns.
    func testRunExportOmitsDeselectedColumns() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.selectedColumnNames.remove("notes")
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("notes"))
        XCTAssertFalse(contents.contains("Standard bolt"))
    }

    func testRunExportToUnwritablePathSetsErrorMessageInsteadOfCrashing() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.options.format = .csv
        viewModel.outputFileURL = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.csv")

        await runToCompletion(viewModel)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: - Paging

    private func seedManyRows(count: Int) async throws {
        try await service.execute("DELETE FROM widgets")
        try await service.execute("ALTER TABLE widgets AUTO_INCREMENT = 1")
        var inserted = 0
        while inserted < count {
            let batchSize = min(100, count - inserted)
            let values = (0..<batchSize)
                .map { "('Row \(inserted + $0)', \(inserted + $0), NULL, NULL)" }
                .joined(separator: ", ")
            try await service.execute("INSERT INTO widgets (name, quantity, created_at, notes) VALUES \(values)")
            inserted += batchSize
        }
    }

    /// Same shape as `DatabaseBackupViewModelTests
    /// .testRunBackupPagesThroughATableLargerThanOnePageWithoutLosingRows`:
    /// a table larger than one page must come out complete, with no row
    /// dropped or duplicated at the page boundary.
    func testKeysetPaginationAcrossAPageBoundaryLosesNoRows() async throws {
        try await seedManyRows(count: 250)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.fetchPageSize = 100
        viewModel.options.format = .sql
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        let insertCount = contents.components(separatedBy: "INSERT INTO").count - 1
        XCTAssertEqual(insertCount, 250, "her satır tam olarak bir kez yazılmalı")
        XCTAssertTrue(contents.contains("'Row 0'"))
        XCTAssertTrue(contents.contains("'Row 99'"))
        XCTAssertTrue(contents.contains("'Row 100'"))
        XCTAssertTrue(contents.contains("'Row 199'"))
        XCTAssertTrue(contents.contains("'Row 200'"))
        XCTAssertTrue(contents.contains("'Row 249'"))
    }

    /// `id` is the primary key; unchecking it removes it from the `SELECT`
    /// list, so there's nothing to seek by — this exercises the `OFFSET`
    /// fallback deliberately, not just incidentally via a no-PK table.
    func testExportFallsBackToOffsetPaginationWhenPrimaryKeyColumnIsDeselected() async throws {
        try await seedManyRows(count: 250)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.selectedColumnNames.remove("id")
        viewModel.fetchPageSize = 100
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        let lines = contents.split(separator: "\r\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 251, "header + 250 satır")
        XCTAssertTrue(contents.contains("Row 0"))
        XCTAssertTrue(contents.contains("Row 249"))
    }

    /// A JSON array streamed across several pages must still be exactly as
    /// valid, and carry exactly as many elements, as the old whole-array
    /// `write(rows:)` path produced — the comma placement strategy differs
    /// under the hood (no known total row count while streaming) but the
    /// output must not.
    func testStreamingJSONExportProducesAValidArrayAcrossAPageBoundary() async throws {
        try await seedManyRows(count: 250)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.fetchPageSize = 100
        viewModel.options.format = .json
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let data = try Data(contentsOf: tempFileURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 250)
        XCTAssertEqual(parsed?.first?["name"] as? String, "Row 0")
        XCTAssertEqual(parsed?.last?["name"] as? String, "Row 249")
    }

    // MARK: - Progress

    /// Mirrors `DatabaseBackupViewModelTests
    /// .testProgressPercentageAdvancesWithinASingleLargeTable` — the
    /// percentage has to move *while* a single table is being read, not
    /// just jump from 0 to 100 when the whole export finishes.
    func testProgressAdvancesAcrossPagesForALargerExport() async throws {
        try await seedManyRows(count: 250)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.fetchPageSize = 50
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        var midRunPercentages: [Double] = []
        viewModel.outputLocationIsGranted = true
        viewModel.startExport()
        while viewModel.isExporting {
            if let progress = viewModel.progress, progress.percentage > 0, progress.percentage < 1 {
                midRunPercentages.append(progress.percentage)
            }
            await Task.yield()
        }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(midRunPercentages.isEmpty, "büyük bir export sırasında yüzde 0 ile 100 arasında en az bir kez ilerlemeli")
        XCTAssertEqual(viewModel.progress?.percentage, 1.0, "bitişte %100 olmalı")
    }

    /// `.xlsx` can't stream to disk (it's a zip built from complete XML
    /// parts) — but the fetch phase feeding it must still report progress,
    /// so a large table isn't a silent, indefinite wait before the one
    /// final write.
    func testProgressAdvancesDuringXLSXFetchPhase() async throws {
        try await seedManyRows(count: 250)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.fetchPageSize = 50
        viewModel.options.format = .xlsx
        viewModel.outputFileURL = tempFileURL

        var midRunPercentages: [Double] = []
        viewModel.outputLocationIsGranted = true
        viewModel.startExport()
        while viewModel.isExporting {
            if let progress = viewModel.progress, progress.percentage > 0, progress.percentage < 1 {
                midRunPercentages.append(progress.percentage)
            }
            await Task.yield()
        }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(midRunPercentages.isEmpty, "xlsx veri çekme aşamasında da ilerleme akmalı")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFileURL.path))
    }

    // MARK: - Excel row limit

    /// The regression guard for the real bug this app hit: `sokaklar`
    /// (1,148,699 rows) exported to a 548MB `.xlsx` that Excel flagged as
    /// damaged on open — its row references (up to `r="1148700"`) exceed
    /// the format's hard ceiling (`XFD1048576`). `xlsxRowLimit` lets this
    /// be exercised without seeding over a million rows.
    func testXLSXExportOverTheRowLimitFailsCleanlyInsteadOfProducingATruncatedFile() async throws {
        try await seedManyRows(count: 10)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.xlsxRowLimit = 5 // 4 data rows + 1 header row
        viewModel.options.format = .xlsx
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path), "sınırı aşan bir export hiç dosya üretmemeli")
    }

    func testXLSXExportAtOrUnderTheRowLimitSucceeds() async throws {
        try await seedManyRows(count: 4)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.xlsxRowLimit = 5 // exactly 4 data rows + 1 header fits
        viewModel.options.format = .xlsx
        viewModel.outputFileURL = tempFileURL

        await runToCompletion(viewModel)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFileURL.path))
    }

    // MARK: - Cancellation / safe writes

    func testCancelExportMidRunLeavesNoPartialFile() async throws {
        try await seedManyRows(count: 250)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.fetchPageSize = 50
        viewModel.interPageDelay = .milliseconds(200)
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        viewModel.outputLocationIsGranted = true
        viewModel.startExport()
        while viewModel.progress == nil { await Task.yield() }
        viewModel.cancelExport()
        while viewModel.isExporting { await Task.yield() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path))
        XCTAssertFalse(viewModel.didFinishSuccessfully, "iptal edilen bir export tamamlanma uyarısını tetiklememeli")
    }

    /// The regression guard for the data-loss bug `AtomicFileWriter` fixed
    /// (found and fixed for `DatabaseBackupViewModel` first): cancelling an
    /// export must not touch whatever was already at `outputFileURL` — a
    /// very plausible thing to exist, since re-exporting into the same path
    /// is a normal workflow.
    func testCancelledExportLeavesAPreexistingFileAtOutputPathUntouched() async throws {
        try await seedManyRows(count: 250)
        try Data("önceki export — bozulmamalı".utf8).write(to: tempFileURL)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.fetchPageSize = 50
        viewModel.interPageDelay = .milliseconds(200)
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        viewModel.outputLocationIsGranted = true
        viewModel.startExport()
        while viewModel.progress == nil { await Task.yield() }
        viewModel.cancelExport()
        while viewModel.isExporting { await Task.yield() }

        XCTAssertEqual(try String(contentsOf: tempFileURL, encoding: .utf8), "önceki export — bozulmamalı")
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: tempFileURL.deletingLastPathComponent().path)) ?? []
        XCTAssertTrue(siblings.filter { $0.hasPrefix(".\(tempFileURL.lastPathComponent).tmp-") }.isEmpty, "geçici dosya artık kalmamalı")
    }
}
