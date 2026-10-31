import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP) — same convention as
/// `TableExportViewModelTests`. Uses the `widgets` seed table (Bolt/Nut/
/// Washer, ids 1-3), reset in `setUp`; `name` is `NOT NULL`, `quantity`/
/// `created_at`/`notes` are nullable (confirmed in
/// `SchemaIntrospectionServiceTests`).
@MainActor
final class TableImportViewModelTests: XCTestCase {
    var service: MySQLService!
    var sourceFileURL: URL!
    var xlsxFileURL: URL!

    override func setUp() async throws {
        sourceFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        xlsxFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
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
        try? FileManager.default.removeItem(at: sourceFileURL)
        try? FileManager.default.removeItem(at: xlsxFileURL)
        _ = try? await service.rawQuery("DROP TABLE IF EXISTS import_scratch_innodb")
        try await service.disconnect()
    }

    private func makeViewModel() -> TableImportViewModel {
        TableImportViewModel(service: service, table: TableInfo(database: "mysqlmacclient_test", name: "widgets", isView: false))
    }

    /// `widgets` (this environment's shared fixture) is `Aria` — Aria only
    /// guarantees crash-safety, not multi-statement `ROLLBACK`, so it can't
    /// prove `TableImportViewModel`'s all-or-nothing behavior either way.
    /// The two rollback tests below run against this private `InnoDB`
    /// scratch table instead, so the guarantee is actually exercised rather
    /// than skipped — confirmed available on this server independently of
    /// the `mysql.proc`/`mariadb-upgrade` issue tracked elsewhere.
    private func makeInnoDBScratchViewModel() -> TableImportViewModel {
        TableImportViewModel(service: service, table: TableInfo(database: "mysqlmacclient_test", name: "import_scratch_innodb", isView: false))
    }

    private func createInnoDBScratchTableWithOneSeedRow() async throws {
        _ = try await service.rawQuery("DROP TABLE IF EXISTS import_scratch_innodb")
        _ = try await service.rawQuery("""
            CREATE TABLE import_scratch_innodb (
                id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(100) NOT NULL,
                quantity INT DEFAULT NULL
            ) ENGINE=InnoDB
            """)
        try await service.execute("INSERT INTO import_scratch_innodb (id, name, quantity) VALUES (1, 'Seed', 0)")
    }

    private func scratchRowCount() async throws -> Int {
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM import_scratch_innodb")
        return rows.first?.column("cnt")?.int ?? 0
    }

    private func write(_ csv: String) throws {
        try Data(csv.utf8).write(to: sourceFileURL)
    }

    /// Runs a started import to completion — `startImport()` is
    /// fire-and-forget (cancellation needs to be reachable from a
    /// different call site), so tests poll `isImporting`, same convention
    /// as `TableExportViewModelTests.runToCompletion`.
    private func runToCompletion(_ viewModel: TableImportViewModel) async {
        viewModel.startImport()
        while viewModel.isImporting { await Task.yield() }
    }

    private func widgetRowCount() async throws -> Int {
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM widgets")
        return rows.first?.column("cnt")?.int ?? 0
    }

    // MARK: - Format selection

    func testDefaultsToCSVAndSwitchingFormatClearsThePreviouslyChosenFile() async throws {
        try write("name,quantity,notes\nScrew,50,Small screw\n")

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        XCTAssertEqual(viewModel.selectedFormat, .csv)

        viewModel.sourceFileURL = sourceFileURL
        await viewModel.refreshColumnMappings()
        XCTAssertNotNil(viewModel.sourceFileURL)
        XCTAssertFalse(viewModel.columnMappings.isEmpty)

        // A CSV file can't just be reinterpreted as an Excel one — the
        // stale selection has to go, not linger as a mismatched pairing.
        viewModel.selectedFormat = .xlsx

        XCTAssertNil(viewModel.sourceFileURL)
        XCTAssertTrue(viewModel.columnMappings.isEmpty)
    }

    // MARK: - Basic import + auto-mapping

    func testImportInsertsAllRowsWithHeadersMatchingColumnNames() async throws {
        try write("name,quantity,notes\nScrew,50,Small screw\nRivet,75,\n")

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.sourceFileURL = sourceFileURL
        await viewModel.refreshColumnMappings()

        XCTAssertEqual(viewModel.columnMappings.map(\.targetColumnName), ["name", "quantity", "notes"])

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.didFinishSuccessfully)

        let rows = try await service.query("SELECT quantity, notes FROM widgets WHERE name = 'Screw'")
        XCTAssertEqual(rows.first?.column("quantity")?.int, 50)
        XCTAssertEqual(rows.first?.column("notes")?.string, "Small screw")

        let rivetRows = try await service.query("SELECT notes FROM widgets WHERE name = 'Rivet'")
        XCTAssertNil(rivetRows.first?.column("notes")?.string, "boş alan nullable kolonda NULL olmalı")

        let count = try await widgetRowCount()
        XCTAssertEqual(count, 5, "3 tohum satırı + 2 içe aktarılan satır")
    }

    /// Source column order doesn't have to match the table's — mapping is
    /// by header *name*, not position.
    func testColumnOrderDifferentFromTargetStillMapsCorrectly() async throws {
        try write("notes,name,quantity\nreordered note,Anchor,12\n")

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.sourceFileURL = sourceFileURL
        await viewModel.refreshColumnMappings()

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let rows = try await service.query("SELECT quantity, notes FROM widgets WHERE name = 'Anchor'")
        XCTAssertEqual(rows.first?.column("quantity")?.int, 12)
        XCTAssertEqual(rows.first?.column("notes")?.string, "reordered note")
    }

    /// A source column with no matching target column (and one the user
    /// doesn't want) is left unmapped and simply skipped — not an error.
    func testUnmatchedSourceColumnIsSkippedNotAnError() async throws {
        try write("name,quantity,extra_column\nSpring,5,ignored value\n")

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.sourceFileURL = sourceFileURL
        await viewModel.refreshColumnMappings()

        XCTAssertEqual(viewModel.columnMappings.first { $0.sourceHeaderName == "extra_column" }?.targetColumnName, nil)

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let rows = try await service.query("SELECT quantity FROM widgets WHERE name = 'Spring'")
        XCTAssertEqual(rows.first?.column("quantity")?.int, 5)
    }

    // MARK: - Batching / progress

    private func csv(rows: Int, startingAt base: Int = 1000) -> String {
        var lines = ["id,name,quantity"]
        for offset in 0..<rows {
            lines.append("\(base + offset),Batch\(base + offset),\(offset)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A file spanning several `insertBatchSize`-sized batches must still
    /// land every row, and the row counter has to move mid-run rather than
    /// jumping straight from 0 to the total — same shape as
    /// `TableExportViewModelTests.testProgressAdvancesAcrossPagesForALargerExport`.
    func testImportBatchesAcrossMultipleInsertsAndProgressAdvances() async throws {
        try write(csv(rows: 120))

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.insertBatchSize = 25
        viewModel.sourceFileURL = sourceFileURL
        await viewModel.refreshColumnMappings()

        var midRunPercentages: [Double] = []
        viewModel.startImport()
        while viewModel.isImporting {
            if let progress = viewModel.progress, progress.percentage > 0, progress.percentage < 1 {
                midRunPercentages.append(progress.percentage)
            }
            await Task.yield()
        }

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(midRunPercentages.isEmpty, "birden fazla batch'e yayılan bir import sırasında ilerleme akmalı")
        XCTAssertEqual(viewModel.progress?.percentage, 1.0)
        let count = try await widgetRowCount()
        XCTAssertEqual(count, 3 + 120, "her satır tam olarak bir kez yazılmalı")
    }

    // MARK: - All-or-nothing transaction

    /// A duplicate primary key partway through the file (id `1`, already
    /// used by the scratch table's seed row) must fail one `INSERT`, and
    /// roll the **entire** transaction back — including whatever earlier
    /// batches already executed successfully but hadn't been committed
    /// yet. Proves the "tamamı ya da hiçbiri" design: nothing here is
    /// per-batch commit.
    func testABadRowRollsBackTheEntireImportEvenAcrossEarlierSuccessfulBatches() async throws {
        try await createInnoDBScratchTableWithOneSeedRow()
        var lines = ["id,name,quantity"]
        for offset in 0..<30 {
            let id = offset == 15 ? 1 : (100 + offset) // row 15 collides with the seed row (id 1)
            lines.append("\(id),Batch\(offset),\(offset)")
        }
        try write(lines.joined(separator: "\n") + "\n")

        let viewModel = makeInnoDBScratchViewModel()
        await viewModel.loadColumns()
        viewModel.insertBatchSize = 10 // the bad row lands in the 2nd batch; the 1st batch must still be undone
        viewModel.sourceFileURL = sourceFileURL
        await viewModel.refreshColumnMappings()

        await runToCompletion(viewModel)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        let count = try await scratchRowCount()
        XCTAssertEqual(count, 1, "başarısız bir batch tüm transaction'ı geri almalı, ilk batch dahil — yalnızca tohum satırı kalmalı")
    }

    func testNoColumnsMappedSetsErrorMessageAndWritesNothing() async throws {
        try write("unrelated_column\nsome value\n")

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.sourceFileURL = sourceFileURL
        await viewModel.refreshColumnMappings()
        XCTAssertTrue(viewModel.columnMappings.allSatisfy { $0.targetColumnName == nil })

        await runToCompletion(viewModel)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.didFinishSuccessfully)
        let count = try await widgetRowCount()
        XCTAssertEqual(count, 3)
    }

    // MARK: - Cancellation

    /// Waits for `progress.completedRows > 0` — not just for `progress` to
    /// exist — before cancelling, so at least one batch's `INSERT` has
    /// genuinely already executed (uncommitted) when the cancellation
    /// hits. Otherwise this could pass vacuously: cancelling before any
    /// batch ran would leave nothing to roll back either way.
    func testCancelImportMidRunRollsBackEverything() async throws {
        try await createInnoDBScratchTableWithOneSeedRow()
        try write(csv(rows: 200, startingAt: 1000))

        let viewModel = makeInnoDBScratchViewModel()
        await viewModel.loadColumns()
        viewModel.insertBatchSize = 20
        viewModel.interBatchDelay = .milliseconds(200)
        viewModel.sourceFileURL = sourceFileURL
        await viewModel.refreshColumnMappings()

        viewModel.startImport()
        while (viewModel.progress?.completedRows ?? 0) == 0 { await Task.yield() }
        viewModel.cancelImport()
        while viewModel.isImporting { await Task.yield() }

        XCTAssertFalse(viewModel.didFinishSuccessfully, "iptal edilen bir import tamamlanma uyarısını tetiklememeli")
        let count = try await scratchRowCount()
        XCTAssertEqual(count, 1, "iptal, önceden başarıyla çalışan batch'ler dahil hiçbir satır bırakmamalı — yalnızca tohum satırı kalmalı")
    }

    // MARK: - XLSX source format

    /// Built with this app's own `XLSXExporter` — sufficient here, since
    /// `XLSXImportParserTests` already separately proves the parser
    /// handles shared strings/DEFLATE/multiple sheets a real-world file
    /// would use. What this file needs to prove is that
    /// `TableImportViewModel` correctly detects `.xlsx` from the file
    /// extension and routes the whole transactional pipeline through
    /// `XLSXImportParser` instead of `CSVImportParser`.
    private func writeXLSX(headers: [String], rows: [[String]], to url: URL) throws {
        let columns = headers.map {
            ColumnInfo(name: $0, mysqlType: "text", isNullable: true, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil)
        }
        let rowValues: [[RowValue]] = rows.map { row in row.map { RowValue.string($0) } }
        try XLSXExporter.write(columns: columns, rows: rowValues, includeHeaderRow: true, to: url)
    }

    func testSelectingExcelFormatImportsAnXLSXFilesRows() async throws {
        try writeXLSX(
            headers: ["name", "quantity", "notes"],
            rows: [["Screw", "50", "Small screw"], ["Rivet", "75", ""]],
            to: xlsxFileURL
        )

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        XCTAssertEqual(viewModel.selectedFormat, .csv, "CSV varsayılan olmalı")
        viewModel.selectedFormat = .xlsx
        viewModel.sourceFileURL = xlsxFileURL
        await viewModel.refreshColumnMappings()

        XCTAssertEqual(viewModel.columnMappings.map(\.targetColumnName), ["name", "quantity", "notes"])

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.didFinishSuccessfully)

        let rows = try await service.query("SELECT quantity, notes FROM widgets WHERE name = 'Screw'")
        XCTAssertEqual(rows.first?.column("quantity")?.int, 50)
        XCTAssertEqual(rows.first?.column("notes")?.string, "Small screw")

        let count = try await widgetRowCount()
        XCTAssertEqual(count, 5, "3 tohum satırı + 2 içe aktarılan satır")
    }

    /// `chooseSourceFile()` itself needs a real `NSOpenPanel`, so this
    /// exercises `selectedSheetIndex` the way the sheet picker's
    /// `onChange` does: set directly, then re-derive the mapping — proving
    /// the *second* sheet's data is what actually gets read and imported,
    /// not just the first one found in the archive.
    func testSelectingTheSecondSheetImportsThatSheetsRowsNotTheFirsts() async throws {
        let firstSheetColumns = [ColumnInfo(name: "name", mysqlType: "text", isNullable: true, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil)]
        try XLSXExporter.write(columns: firstSheetColumns, rows: [[.string("WrongSheet")]], includeHeaderRow: true, to: xlsxFileURL)

        // `XLSXExporter` only ever writes one sheet — append a second sheet
        // by hand so there's something real to pick between, packaged with
        // `/usr/bin/zip` the same way `XLSXImportParserTests` builds its
        // multi-sheet fixture.
        let secondSheetXML = """
            <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>name</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>RightSheet</t></is></c></row></sheetData></worksheet>
            """
        try appendSecondSheet(sheetXML: secondSheetXML, to: xlsxFileURL)

        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.selectedFormat = .xlsx
        viewModel.sourceFileURL = xlsxFileURL
        await viewModel.refreshColumnMappings()
        XCTAssertEqual(viewModel.xlsxSheetNames, ["Sheet1", "Sheet2"])

        viewModel.selectedSheetIndex = 1
        await viewModel.refreshColumnMappings()

        await runToCompletion(viewModel)
        XCTAssertNil(viewModel.errorMessage)

        let count = try await service.query("SELECT COUNT(*) AS cnt FROM widgets WHERE name = 'RightSheet'")
        XCTAssertEqual(count.first?.column("cnt")?.int, 1)
        let wrongCount = try await service.query("SELECT COUNT(*) AS cnt FROM widgets WHERE name = 'WrongSheet'")
        XCTAssertEqual(wrongCount.first?.column("cnt")?.int, 0, "seçilmeyen sayfanın verisi içe aktarılmamalı")
    }

    /// Rewrites the `.xlsx` at `url` (a `XLSXExporter`-produced archive,
    /// single sheet named "Sheet1") to add a second sheet — patches
    /// `workbook.xml`/`workbook.xml.rels` to reference it and repacks
    /// everything with `/usr/bin/zip`, an independent tool actually doing
    /// the archiving rather than this project's own writer.
    private func appendSecondSheet(sheetXML: String, to url: URL) throws {
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        try runProcess("/usr/bin/unzip", ["-q", url.path, "-d", stagingDir.path])

        let workbookURL = stagingDir.appendingPathComponent("xl/workbook.xml")
        var workbookXML = try String(contentsOf: workbookURL, encoding: .utf8)
        workbookXML = workbookXML.replacingOccurrences(
            of: "</sheets>",
            with: "<sheet name=\"Sheet2\" sheetId=\"2\" r:id=\"rId2\"/></sheets>"
        )
        try workbookXML.write(to: workbookURL, atomically: true, encoding: .utf8)

        let relsURL = stagingDir.appendingPathComponent("xl/_rels/workbook.xml.rels")
        var relsXML = try String(contentsOf: relsURL, encoding: .utf8)
        relsXML = relsXML.replacingOccurrences(
            of: "</Relationships>",
            with: "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet2.xml\"/></Relationships>"
        )
        try relsXML.write(to: relsURL, atomically: true, encoding: .utf8)

        try sheetXML.write(to: stagingDir.appendingPathComponent("xl/worksheets/sheet2.xml"), atomically: true, encoding: .utf8)

        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", url.path, "."]
        process.currentDirectoryURL = stagingDir
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "/usr/bin/zip failed to repack the test fixture")
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }
}
