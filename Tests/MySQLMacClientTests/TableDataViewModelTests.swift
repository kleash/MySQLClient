import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP), not a mock — see
/// MySQLClient.md's validation plan. Each test resets the `widgets` seed
/// data in setUp and re-queries the database directly after ViewModel
/// mutations rather than trusting the optimistic in-memory state.
///
/// Query-panel behavior (running SQL, query-result editing) now lives in
/// `SQLConsoleViewModel` — see `SQLConsoleViewModelTests` for that.
@MainActor
final class TableDataViewModelTests: XCTestCase {
    var service: MySQLService!
    var introspection: SchemaIntrospectionService!

    override func setUp() async throws {
        service = MySQLService()
        try await service.connect(
            host: TestDatabase.host,
            port: TestDatabase.port,
            username: TestDatabase.username,
            password: TestDatabase.password,
            database: "mysqlmacclient_test"
        )
        introspection = SchemaIntrospectionService(service: service)
        try await resetWidgets()
    }

    override func tearDown() async throws {
        try await service.disconnect()
    }

    /// A grid wired to a throwaway history file, so the assertions below
    /// never touch the real history under Application Support.
    private func makeViewModelWithHistory(
        tableName: String = "widgets",
        profileID: UUID
    ) -> (viewModel: TableDataViewModel, history: QueryHistoryStore, fileURL: URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grid-history-\(UUID().uuidString).json")
        let history = QueryHistoryStore(fileURL: fileURL)
        let viewModel = TableDataViewModel(
            databaseName: "mysqlmacclient_test",
            tableName: tableName,
            service: service,
            introspection: introspection,
            historyRecorder: QueryHistoryRecorder(
                store: history,
                profileID: profileID,
                isEnabled: { true }
            )
        )
        return (viewModel, history, fileURL)
    }

    // MARK: - The draft row

    /// "Satır Ekle" only adds a row to the grid: until the user leaves it,
    /// the table must be untouched.
    func testAddDraftRowWritesNothingUntilTheRowIsLeft() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()

        XCTAssertEqual(viewModel.rows.count, 4, "taslak satır ızgarada görünmeli")
        XCTAssertEqual(viewModel.rows.last?.isDraft, true)
        XCTAssertEqual(viewModel.rowIDToFocus, viewModel.draftRowID, "taslak satır seçili hale getirilmeli")
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM widgets")
        XCTAssertEqual(rows.first?.column("cnt")?.int, 3, "veritabanına henüz hiçbir şey yazılmamalı")
    }

    /// A second click shouldn't stack up pending rows.
    func testAddDraftRowTwiceKeepsASinglePendingRow() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()
        viewModel.addDraftRow()

        XCTAssertEqual(viewModel.rows.filter(\.isDraft).count, 1)
    }

    /// Leaving the row is what inserts it — and only the columns actually
    /// typed into are sent, so `id` keeps its AUTO_INCREMENT value and
    /// untouched columns keep their DEFAULT.
    func testCommitDraftRowInsertsOnlyTheFilledColumns() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()
        let draftID = try XCTUnwrap(viewModel.draftRowID)
        await viewModel.commitEdit(rowId: draftID, column: "name", newText: "Gear")
        XCTAssertEqual(viewModel.rows.count, 4, "düzenleme sırasında satır hâlâ taslak")

        await viewModel.commitDraftRow()
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.draftRowID, "taslak gerçek satıra dönüşmeli")

        let rows = try await service.query("SELECT name, quantity FROM widgets WHERE name = 'Gear'")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.column("quantity")?.int, "dokunulmayan kolon INSERT'e girmemeli")
    }

    /// The row that was just written is the one the grid should land on.
    func testCommitDraftRowPointsTheGridAtTheInsertedRow() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()
        let draftID = try XCTUnwrap(viewModel.draftRowID)
        await viewModel.commitEdit(rowId: draftID, column: "name", newText: "Gear")
        await viewModel.commitDraftRow()

        let focusedID = try XCTUnwrap(viewModel.rowIDToFocus, "eklenen satır işaretlenmeli")
        let focused = try XCTUnwrap(viewModel.rows.first { $0.id == focusedID })
        XCTAssertFalse(focused.isDraft)
        XCTAssertEqual(focused.originalValues["name"]?.displayString, "Gear")
    }

    /// Clicking "Satır Ekle" and changing your mind must not write anything.
    func testCommitDraftRowDiscardsAnUntouchedDraft() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()
        await viewModel.commitDraftRow()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.draftRowID)
        XCTAssertFalse(viewModel.rows.contains(where: \.isDraft), "boş taslak ızgaradan da kalkmalı")
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM widgets")
        XCTAssertEqual(rows.first?.column("cnt")?.int, 3)
    }

    /// A failing INSERT (here: a duplicate primary key) has to leave the
    /// typed row on screen to be fixed, not swallow it.
    func testFailedDraftInsertKeepsTheRowAndReportsTheError() async throws {
        try await service.execute("DELETE FROM manual_pk_items")
        try await service.execute("INSERT INTO manual_pk_items (item_code, label) VALUES (42, 'existing')")
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "manual_pk_items", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()
        let draftID = try XCTUnwrap(viewModel.draftRowID)
        await viewModel.commitEdit(rowId: draftID, column: "item_code", newText: "42")
        await viewModel.commitEdit(rowId: draftID, column: "label", newText: "duplicate")
        await viewModel.commitDraftRow()

        XCTAssertNotNil(viewModel.errorMessage, "sunucunun hatası gösterilmeli")
        XCTAssertEqual(viewModel.draftRowID, draftID, "satır düzeltilebilmek için taslak kalmalı")
        XCTAssertEqual(viewModel.rows.first { $0.id == draftID }?.editedText["label"], "duplicate", "yazılanlar korunmalı")
    }

    /// The trash button on a pending row drops it locally — no DELETE.
    func testDeletingADraftRowJustRemovesItFromTheGrid() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()
        let draft = try XCTUnwrap(viewModel.rows.last)
        await viewModel.deleteRow(draft)

        XCTAssertNil(viewModel.draftRowID)
        XCTAssertEqual(viewModel.rows.count, 3)
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM widgets")
        XCTAssertEqual(rows.first?.column("cnt")?.int, 3)
    }

    /// Sorting/filtering/paging all refetch `rows`, which would drop the
    /// pending row silently — it's committed first instead.
    func testRefetchCommitsThePendingRowFirst() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()
        let draftID = try XCTUnwrap(viewModel.draftRowID)
        await viewModel.commitEdit(rowId: draftID, column: "name", newText: "Gear")
        await viewModel.applySort(column: "name", ascending: true)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.draftRowID)
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM widgets WHERE name = 'Gear'")
        XCTAssertEqual(rows.first?.column("cnt")?.int, 1)
    }

    /// With an auto-increment key the new row sorts to the end, which on a
    /// paginated table isn't the page being viewed — the view model has to
    /// move to the last page rather than report "not found".
    func testCommitDraftRowJumpsToTheLastPageToReachTheNewRow() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection, pageSize: 2)
        await viewModel.load()
        XCTAssertEqual(viewModel.currentOffset, 0, "ilk sayfadayız")

        viewModel.addDraftRow()
        let draftID = try XCTUnwrap(viewModel.draftRowID)
        await viewModel.commitEdit(rowId: draftID, column: "name", newText: "Gear")
        await viewModel.commitDraftRow()
        XCTAssertNil(viewModel.errorMessage)

        XCTAssertNotEqual(viewModel.currentOffset, 0, "yeni satır için son sayfaya geçilmeli")
        let focusedID = try XCTUnwrap(viewModel.rowIDToFocus)
        XCTAssertTrue(viewModel.rows.contains { $0.id == focusedID }, "işaretlenen satır görünen sayfada olmalı")
    }

    /// A manually-assigned (non auto-increment) key isn't covered by
    /// `lastInsertID`; the row still has to be found, using the value the
    /// insert actually wrote.
    func testCommitDraftRowFindsTheNewRowWithAManualPrimaryKey() async throws {
        try await service.execute("DELETE FROM manual_pk_items")
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "manual_pk_items", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()
        let draftID = try XCTUnwrap(viewModel.draftRowID)
        await viewModel.commitEdit(rowId: draftID, column: "item_code", newText: "42")
        await viewModel.commitEdit(rowId: draftID, column: "label", newText: "Gear")
        await viewModel.commitDraftRow()
        XCTAssertNil(viewModel.errorMessage)

        let focusedID = try XCTUnwrap(viewModel.rowIDToFocus, "manuel PK'lı tabloda da işaretlenmeli")
        let focused = try XCTUnwrap(viewModel.rows.first { $0.id == focusedID })
        XCTAssertEqual(focused.originalValues["item_code"]?.displayString, "42")
    }

    // MARK: - Query history for grid-driven writes

    /// The grid's trash button, "Satır Ekle" and cell editing all run SQL
    /// on the user's behalf; each has to land in the connection's history
    /// with its bound values filled in, tagged as app-generated.
    func testGridWritesAreRecordedInHistoryWithValuesFilledIn() async throws {
        let profileID = UUID()
        let (viewModel, history, fileURL) = makeViewModelWithHistory(profileID: profileID)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        await viewModel.load()

        // Cell edit -> UPDATE
        guard let bolt = viewModel.rows.first(where: { $0.originalValues["name"]?.displayString == "Bolt" }) else {
            return XCTFail("seed row missing")
        }
        await viewModel.commitEdit(rowId: bolt.id, column: "quantity", newText: "321")
        XCTAssertNil(viewModel.errorMessage)

        let updateEntry = history.entries(for: profileID).first
        XCTAssertEqual(updateEntry?.source, .app)
        XCTAssertEqual(updateEntry?.database, "mysqlmacclient_test")
        XCTAssertEqual(updateEntry?.sql.contains("?"), false, "değerler doldurulmuş olmalı")
        XCTAssertEqual(updateEntry?.sql.contains("'321'"), true)

        // Row insert -> INSERT, logged when the draft row is committed
        viewModel.addDraftRow()
        let draftID = try XCTUnwrap(viewModel.draftRowID)
        await viewModel.commitEdit(rowId: draftID, column: "name", newText: "Gear")
        await viewModel.commitDraftRow()
        XCTAssertNil(viewModel.errorMessage)
        let insertEntry = history.entries(for: profileID).first
        XCTAssertEqual(insertEntry?.sql.hasPrefix("INSERT INTO"), true)
        XCTAssertEqual(insertEntry?.sql.contains("'Gear'"), true, "değerler doldurulmuş olmalı")

        // Row delete -> DELETE
        guard let washer = viewModel.rows.first(where: { $0.originalValues["name"]?.displayString == "Washer" }) else {
            return XCTFail("seed row missing")
        }
        await viewModel.deleteRow(washer)
        XCTAssertNil(viewModel.errorMessage)
        let deleteEntry = history.entries(for: profileID).first
        XCTAssertEqual(deleteEntry?.sql.hasPrefix("DELETE FROM"), true)
        XCTAssertEqual(deleteEntry?.sql.contains("?"), false)
    }

    /// Reads must not be logged — the grid re-queries on every page,
    /// sort and filter, which would bury the history in SELECTs.
    func testGridReadsAreNotRecorded() async throws {
        let profileID = UUID()
        let (viewModel, history, fileURL) = makeViewModelWithHistory(profileID: profileID)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await viewModel.load()
        await viewModel.applySort(column: "name", ascending: true)
        await viewModel.applyFilter(column: "name", value: "Bolt")
        await viewModel.reload()

        XCTAssertTrue(history.entries(for: profileID).isEmpty)
    }

    private func resetWidgets() async throws {
        try await service.execute("DELETE FROM widgets")
        try await service.execute("ALTER TABLE widgets AUTO_INCREMENT = 1")
        try await service.execute("""
            INSERT INTO widgets (name, quantity, created_at, notes) VALUES
            ('Bolt', 100, '2024-01-15 10:30:00', 'Standard bolt'),
            ('Nut', 250, '2024-02-20 14:00:00', NULL),
            ('Washer', NULL, NULL, 'Out of stock')
            """)
    }

    private func row(_ viewModel: TableDataViewModel, named name: String) -> TableRow? {
        viewModel.rows.first { $0.originalValues["name"]?.displayString == name }
    }

    func testLoadFetchesColumnsAndRows() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.hasPrimaryKey)
        XCTAssertEqual(viewModel.totalRowCount, 3)
        XCTAssertEqual(viewModel.rows.count, 3)
        XCTAssertEqual(viewModel.columns.map(\.name).sorted(), ["created_at", "id", "name", "notes", "quantity"])
    }

    func testTableWithoutPrimaryKeyDisablesEditing() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widget_logs_nopk", service: service, introspection: introspection)
        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.hasPrimaryKey)
    }

    func testCommitEditUpdatesOnlyTheChangedColumn() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()
        guard let bolt = row(viewModel, named: "Bolt") else { return XCTFail("seed row missing") }

        await viewModel.commitEdit(rowId: bolt.id, column: "quantity", newText: "999")
        XCTAssertNil(viewModel.errorMessage)

        let rows = try await service.query("SELECT quantity, notes FROM widgets WHERE id = 1")
        XCTAssertEqual(rows.first?.column("quantity")?.int, 999)
        XCTAssertEqual(rows.first?.column("notes")?.string, "Standard bolt")
    }

    func testCommitEditEmptyTextOnNullableColumnWritesNull() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()
        guard let nut = row(viewModel, named: "Nut") else { return XCTFail("seed row missing") }

        await viewModel.commitEdit(rowId: nut.id, column: "quantity", newText: "")
        XCTAssertNil(viewModel.errorMessage)

        let rows = try await service.query("SELECT quantity FROM widgets WHERE id = 2")
        XCTAssertNil(rows.first?.column("quantity")?.int)
    }

    func testDeleteRowRemovesFromDatabase() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()
        guard let washer = row(viewModel, named: "Washer") else { return XCTFail("seed row missing") }

        await viewModel.deleteRow(washer)
        XCTAssertNil(viewModel.errorMessage)

        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM widgets")
        XCTAssertEqual(rows.first?.column("cnt")?.int, 2)
    }

    func testCommitDraftRowAddsRowToDatabase() async throws {
        // `tags` has only an auto-increment PK and a nullable `name`, so a
        // one-column draft is guaranteed to insert cleanly.
        try await service.execute("DELETE FROM tags")
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "tags", service: service, introspection: introspection)
        await viewModel.load()

        viewModel.addDraftRow()
        let draftID = try XCTUnwrap(viewModel.draftRowID)
        let editableColumn = try XCTUnwrap(viewModel.columns.first { !$0.isAutoIncrement })
        await viewModel.commitEdit(rowId: draftID, column: editableColumn.name, newText: "urgent")
        await viewModel.commitDraftRow()
        XCTAssertNil(viewModel.errorMessage)

        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM tags")
        XCTAssertEqual(rows.first?.column("cnt")?.int, 1)
    }

    func testPaginationLimitsRowsPerPage() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection, pageSize: 2)
        await viewModel.load()

        XCTAssertEqual(viewModel.rows.count, 2, "explicit pageSize'ın LIMIT cümlesine yansıması gerekiyor")
        XCTAssertEqual(viewModel.totalRowCount, 3)

        await viewModel.nextPage()
        XCTAssertEqual(viewModel.rows.count, 1)
    }

    /// The "Sınırlı" checkbox: unchecked ignores `pageSize` entirely and
    /// loads every row.
    func testDisablingPaginationLoadsTheWholeTableIgnoringPageSize() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection, pageSize: 2)
        await viewModel.load()
        XCTAssertEqual(viewModel.rows.count, 2)

        await viewModel.setPaginationEnabled(false)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.rows.count, 3, "sayfalama kapalıyken tüm satırlar yüklenmeli")

        await viewModel.setPaginationEnabled(true)
        XCTAssertEqual(viewModel.rows.count, 2, "tekrar açıldığında pageSize'a dönmeli")
    }

    func testFilterNarrowsRows() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        await viewModel.applyFilter(column: "name", value: "Bolt")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.totalRowCount, 1)
        XCTAssertEqual(viewModel.rows.first?.originalValues["name"]?.displayString, "Bolt")
    }

    func testApplySortOrdersRowsAndTogglingFlipsDirection() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        await viewModel.applySort(column: "name", ascending: true)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.rows.map { $0.originalValues["name"]?.displayString }, ["Bolt", "Nut", "Washer"])

        await viewModel.applySort(column: "name", ascending: false)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.rows.map { $0.originalValues["name"]?.displayString }, ["Washer", "Nut", "Bolt"])
    }

    func testShowTableInfoBuildsTextReportFromLiveSchema() async throws {
        let viewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await viewModel.load()

        await viewModel.showTableInfo()

        let report = try XCTUnwrap(viewModel.tableInfoText)
        XCTAssertTrue(report.contains("/*Table: widgets*/"))
        XCTAssertTrue(report.contains("/*Column Information*/"))
        XCTAssertTrue(report.contains("Field"), "SHOW FULL COLUMNS başlıkları görünmeli")
        XCTAssertTrue(report.contains("id"))
        XCTAssertTrue(report.contains("/*Index Information*/"))
        XCTAssertTrue(report.contains("PRIMARY"))
        XCTAssertTrue(report.contains("/*DDL Information*/"))
        XCTAssertTrue(report.contains("CREATE TABLE"))
    }
}
