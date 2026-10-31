import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP), not a mock.
///
/// `SQLConsoleViewModel` is the session-level SQL editor — it used to live
/// inside `TableDataViewModel` (one per selected table), which meant the
/// editor simply didn't exist with no table selected. That was a real dead
/// end: a brand-new, still-empty database has nothing in the sidebar to
/// select, so there was no way to reach the editor to run a first
/// `CREATE TABLE`. `SQLConsoleViewModel` is now created once per connected
/// session and shared regardless of table selection — several tests below
/// exercise it exactly that way, with no `currentDatabaseHint` at all, to
/// prove that scenario now works.
@MainActor
final class SQLConsoleViewModelTests: XCTestCase {
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
        try await service.execute("DROP TABLE IF EXISTS console_scratch")
        try await service.execute("DROP VIEW IF EXISTS console_scratch_view")
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS console_scratch_proc")
        _ = try await service.rawQuery("DROP FUNCTION IF EXISTS console_scratch_fn")
    }

    override func tearDown() async throws {
        try await service.execute("DROP TABLE IF EXISTS console_scratch")
        try await service.execute("DROP VIEW IF EXISTS console_scratch_view")
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS console_scratch_proc")
        _ = try await service.rawQuery("DROP FUNCTION IF EXISTS console_scratch_fn")
        try await service.disconnect()
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

    private func makeConsole(defaultSelectLimit: Int? = nil) -> SQLConsoleViewModel {
        SQLConsoleViewModel(service: service, introspection: introspection, defaultSelectLimit: defaultSelectLimit ?? 1000)
    }

    /// A console wired to a throwaway history file, so history assertions
    /// never touch the real one under Application Support.
    private func makeConsoleWithHistory(
        profileID: UUID,
        historyEnabled: Bool = true
    ) -> (console: SQLConsoleViewModel, history: QueryHistoryStore, fileURL: URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-history-\(UUID().uuidString).json")
        let history = QueryHistoryStore(fileURL: fileURL)
        let console = SQLConsoleViewModel(
            service: service,
            introspection: introspection,
            defaultSelectLimit: 1000,
            historyRecorder: QueryHistoryRecorder(
                store: history,
                profileID: profileID,
                // Explicit, so these tests don't depend on whatever the
                // user has toggled in their real settings.json.
                isEnabled: { historyEnabled }
            )
        )
        return (console, history, fileURL)
    }

    // MARK: - Query history

    func testRunQueryRecordsTheQueryInHistory() async throws {
        let profileID = UUID()
        let (console, history, fileURL) = makeConsoleWithHistory(profileID: profileID)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        console.currentDatabaseHint = "mysqlmacclient_test"
        console.queryText = "SELECT name FROM widgets WHERE name = 'Bolt'"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        let entries = history.entries(for: profileID)
        XCTAssertEqual(entries.first?.sql, "SELECT name FROM widgets WHERE name = 'Bolt'")
        XCTAssertEqual(entries.first?.database, "mysqlmacclient_test")
        XCTAssertEqual(console.queryHistory.first?.sql, entries.first?.sql)
    }

    /// A query that fails is recorded too — recalling the long statement
    /// you just typo'd is the main reason to have history at all.
    func testFailedQueryIsStillRecorded() async throws {
        let profileID = UUID()
        let (console, history, fileURL) = makeConsoleWithHistory(profileID: profileID)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        console.queryText = "SELEKT * FROM widgets"
        await console.runQuery()

        XCTAssertNotNil(console.queryErrorMessage, "sorgu gerçekten başarısız olmalı")
        XCTAssertEqual(history.entries(for: profileID).first?.sql, "SELEKT * FROM widgets")
    }

    /// Only the text actually sent is recorded — with a selection, that's
    /// the selection, not the whole editor.
    func testOnlyTheExecutedSelectionIsRecorded() async throws {
        let profileID = UUID()
        let (console, history, fileURL) = makeConsoleWithHistory(profileID: profileID)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        console.currentDatabaseHint = "mysqlmacclient_test"
        console.queryText = "UPDATE widgets SET quantity = 42 WHERE name = 'Bolt'"
        console.querySelectedText = "SELECT name FROM widgets WHERE name = 'Nut'"
        await console.runQuery()

        XCTAssertEqual(history.entries(for: profileID).map(\.sql), ["SELECT name FROM widgets WHERE name = 'Nut'"])
    }

    func testClearQueryHistoryEmptiesThisProfilesHistory() async throws {
        let profileID = UUID()
        let (console, history, fileURL) = makeConsoleWithHistory(profileID: profileID)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        console.queryText = "SELECT 1"
        await console.runQuery()
        XCTAssertFalse(console.queryHistory.isEmpty)

        console.clearQueryHistory()
        XCTAssertTrue(console.queryHistory.isEmpty)
        XCTAssertTrue(history.entries(for: profileID).isEmpty)
    }

    /// The "Sorgu geçmişini kaydet" opt-out has to actually stop recording
    /// — queries can carry sensitive literals, so this must be a real
    /// switch, not just a hidden list.
    func testHistoryIsNotRecordedWhenTheSettingIsOff() async throws {
        let profileID = UUID()
        let (console, history, fileURL) = makeConsoleWithHistory(profileID: profileID, historyEnabled: false)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        console.queryText = "SELECT name FROM widgets"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage, "sorgu yine de çalışmalı")
        XCTAssertTrue(history.entries(for: profileID).isEmpty)
        XCTAssertTrue(console.queryHistory.isEmpty)
    }

    /// A console with no profile behind it (the test default) must not
    /// crash or try to record anywhere.
    func testConsoleWithoutAProfileRecordsNothing() async throws {
        let console = makeConsole()
        console.queryText = "SELECT 1"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertTrue(console.queryHistory.isEmpty)
    }

    // MARK: - No table selected at all (the reported bug)

    func testCreatesATableWithNoCurrentDatabaseHintAtAllUsingAFullyQualifiedStatement() async throws {
        // The exact scenario reported: a brand-new database with nothing
        // to select in the sidebar, and the user has a CREATE TABLE
        // statement in hand. `currentDatabaseHint` is deliberately left
        // nil — nothing was ever selected.
        let console = makeConsole()
        XCTAssertNil(console.currentDatabaseHint)

        console.queryText = """
            CREATE TABLE `mysqlmacclient_test`.`console_scratch` (
              id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
              label VARCHAR(50) NOT NULL
            )
            """
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        let tables = try await introspection.listTablesAndViews(inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(tables.contains { $0.name == "console_scratch" })
    }

    /// The real regression guard for the bug this fix addresses: a
    /// connection that was never given a default database at connect time
    /// (this app's normal multi-database browsing connection — unlike
    /// every other test here, which uses `database: "mysqlmacclient_test"`
    /// at connect time and so never exposed this) used to reject even an
    /// *unqualified* statement with "No database selected", despite
    /// `currentDatabaseHint` correctly reflecting the sidebar selection.
    /// `runQuery()` now issues a real `USE` first when the hint is set.
    func testUnqualifiedStatementSucceedsOnAConnectionWithNoDefaultDatabaseWhenHintIsSet() async throws {
        let noDefaultDBService = MySQLService()
        try await noDefaultDBService.connect(
            host: TestDatabase.host,
            port: TestDatabase.port,
            username: TestDatabase.username,
            password: TestDatabase.password,
            database: nil
        )
        try await noDefaultDBService.execute("DROP TABLE IF EXISTS mysqlmacclient_test.console_scratch_no_default_db")

        let console = SQLConsoleViewModel(
            service: noDefaultDBService,
            introspection: SchemaIntrospectionService(service: noDefaultDBService),
            defaultSelectLimit: 1000
        )
        console.currentDatabaseHint = "mysqlmacclient_test"
        console.queryText = "CREATE TABLE console_scratch_no_default_db (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY)"

        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        let tables = try await introspection.listTablesAndViews(inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(tables.contains { $0.name == "console_scratch_no_default_db" })

        try await noDefaultDBService.execute("DROP TABLE IF EXISTS mysqlmacclient_test.console_scratch_no_default_db")
        try await noDefaultDBService.disconnect()
    }

    func testRunQuerySelectSucceedsWithNoTableSelectedUsingAFullyQualifiedName() async throws {
        let console = makeConsole()

        console.queryText = "SELECT name FROM `mysqlmacclient_test`.`widgets` WHERE quantity > 100"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertTrue(console.isShowingQueryResult, "sonuç, tablo seçili olmasa da gösterilmeli")
        XCTAssertEqual(console.queryResultRows.map { $0.originalValues["name"]?.displayString }, ["Nut"])
    }

    /// End-to-end for the "Alter View" context-menu action's whole
    /// pipeline: a real `SHOW CREATE VIEW` definition, reformatted by
    /// `ViewAlterStatement` into a `DELIMITER $$ ... DELIMITER ;` script,
    /// must actually run in the console — not just parse correctly in
    /// isolation. `DELIMITER` is a `mysql`-CLI-only directive with no
    /// server-side meaning, so this is the regression test for the bug
    /// where running that script verbatim failed with a syntax error at
    /// `DELIMITER $$`.
    func testRunQueryExecutesDelimiterWrappedAlterViewScript() async throws {
        let console = makeConsole()
        try await service.execute("CREATE VIEW console_scratch_view AS SELECT id, name FROM widgets")
        let createView = try await introspection.showCreateView("console_scratch_view", inDatabase: "mysqlmacclient_test")

        console.queryText = ViewAlterStatement.format(
            database: "mysqlmacclient_test",
            view: "console_scratch_view",
            createView: createView
        )
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        let tables = try await introspection.listTablesAndViews(inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(tables.contains { $0.name == "console_scratch_view" && $0.isView })
    }

    /// End-to-end for the "Alter Procedure" context-menu action: a real
    /// `SHOW CREATE PROCEDURE` definition, wrapped by
    /// `RoutineAlterStatement` into a `DELIMITER $$ ... DELIMITER ;`
    /// script, must actually run in the console (drop, then recreate).
    func testRunQueryExecutesDelimiterWrappedAlterProcedureScript() async throws {
        let console = makeConsole()
        _ = try await service.rawQuery("""
            CREATE PROCEDURE console_scratch_proc(IN newQuantity INT)
            BEGIN
                UPDATE widgets SET quantity = newQuantity WHERE name = 'Bolt';
            END
            """)
        let routine = RoutineInfo(database: "mysqlmacclient_test", name: "console_scratch_proc", kind: .procedure)
        let createProcedure = try await introspection.showCreateRoutine(routine)

        console.queryText = RoutineAlterStatement.format(routine: routine, createStatement: createProcedure)
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        let procedures = try await introspection.listRoutines(.procedure, inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(procedures.contains { $0.name == "console_scratch_proc" })

        _ = try await service.rawQuery("CALL console_scratch_proc(555)")
        let check = try await service.query("SELECT quantity FROM widgets WHERE name = 'Bolt'")
        XCTAssertEqual(check.first?.column("quantity")?.int, 555)
    }

    /// The same round trip for a function — the kind has to carry through
    /// `SHOW CREATE FUNCTION`, `DROP FUNCTION` and the recreate, and the
    /// rebuilt function must still compute the right value.
    func testRunQueryExecutesDelimiterWrappedAlterFunctionScript() async throws {
        let console = makeConsole()
        _ = try await service.rawQuery("""
            CREATE FUNCTION console_scratch_fn(p INT) RETURNS INT READS SQL DATA
            BEGIN
                RETURN p * 3;
            END
            """)
        let routine = RoutineInfo(database: "mysqlmacclient_test", name: "console_scratch_fn", kind: .function)
        let createFunction = try await introspection.showCreateRoutine(routine)

        console.queryText = RoutineAlterStatement.format(routine: routine, createStatement: createFunction)
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        let functions = try await introspection.listRoutines(.function, inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(functions.contains { $0.name == "console_scratch_fn" })

        let value = try await service.query("SELECT console_scratch_fn(7) AS result")
        XCTAssertEqual(value.first?.column("result")?.int, 21)
    }

    /// A `CALL` to a procedure with two `SELECT`s must surface as two
    /// separate result sets (the console renders them as tabs), each with
    /// its own columns — not merged into one list, which is what happens if
    /// the boundaries aren't tracked while reading the response.
    func testRunQueryKeepsProcedureResultSetsSeparate() async throws {
        let console = makeConsole()
        _ = try await service.rawQuery("""
            CREATE PROCEDURE console_scratch_proc()
            BEGIN
                SELECT name FROM widgets WHERE name = 'Bolt';
                SELECT quantity FROM widgets WHERE name = 'Nut';
            END
            """)

        console.queryText = "CALL console_scratch_proc()"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertEqual(console.queryResultSets.count, 2)
        XCTAssertEqual(console.queryResultSets.first?.columns, ["name"])
        XCTAssertEqual(console.queryResultSets.last?.columns, ["quantity"])

        // The grid follows the selected tab.
        XCTAssertEqual(console.selectedResultSetIndex, 0)
        XCTAssertEqual(console.queryResultColumns, ["name"])
        XCTAssertEqual(console.queryResultRows.first?.originalValues["name"]?.displayString, "Bolt")

        console.selectedResultSetIndex = 1
        XCTAssertEqual(console.queryResultColumns, ["quantity"])
        XCTAssertEqual(console.queryResultRows.first?.originalValues["quantity"]?.displayString, "250")

        // Multi-result output is never editable — a row can't be mapped
        // back to a single table.
        XCTAssertNil(console.queryEditContext)
    }

    /// A stale tab index from a previous, wider result must not crash or
    /// show nothing when the next query returns fewer result sets.
    func testSelectedResultSetIndexSurvivesAShrinkingResultCount() async throws {
        let console = makeConsole()
        console.selectedResultSetIndex = 5

        console.queryText = "SELECT name FROM widgets WHERE name = 'Bolt'"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertEqual(console.queryResultSets.count, 1)
        XCTAssertEqual(console.queryResultColumns, ["name"], "must fall back to the first result set")
    }

    /// The exact reported case: a plain, undelimited multi-statement
    /// script (`USE db;\ncall proc();`) fails under `runQuery()` — MySQL
    /// parses the whole two-line string as one statement (no
    /// `CLIENT_MULTI_STATEMENTS` capability negotiated) and errors on the
    /// second line — but must succeed under `runAllStatements()`, which
    /// splits on every top-level `;` with no `DELIMITER` required first.
    func testRunAllStatementsSplitsAPlainUndelimitedScript() async throws {
        let console = makeConsole()
        try await service.rawQuery("""
            CREATE PROCEDURE console_scratch_proc(IN newQuantity INT)
            BEGIN
                UPDATE widgets SET quantity = newQuantity WHERE name = 'Bolt';
            END
            """)

        console.queryText = "USE `mysqlmacclient_test`;\ncall console_scratch_proc(777);"
        await console.runAllStatements()

        XCTAssertNil(console.queryErrorMessage)
        let check = try await service.query("SELECT quantity FROM widgets WHERE name = 'Bolt'")
        XCTAssertEqual(check.first?.column("quantity")?.int, 777)

        try await service.rawQuery("DROP PROCEDURE IF EXISTS console_scratch_proc")
    }

    func testToggleQueryPanelWithNoTableHintOpensABlankEditor() {
        let console = makeConsole()
        console.toggleQueryPanel(defaultTable: nil)

        XCTAssertTrue(console.isQueryPanelVisible)
        XCTAssertEqual(console.queryText, "", "seçili tablo yoksa önceden doldurulacak bir şeyi de yok")
    }

    // MARK: - Table selected (existing behavior, preserved)

    func testToggleQueryPanelFillsDefaultTemplateUsingProvidedTableHint() {
        let console = makeConsole(defaultSelectLimit: 77)
        console.toggleQueryPanel(defaultTable: (database: "mysqlmacclient_test", table: "widgets"))

        XCTAssertTrue(console.isQueryPanelVisible)
        XCTAssertTrue(console.queryText.contains("LIMIT 77;"), "varsayılan sorgu şablonu ayarı kullanmalı: \(console.queryText)")
    }

    func testRunQuerySelectShowsReadOnlyResultInPlaceOfTheGrid() async throws {
        let console = makeConsole()

        console.queryText = "SELECT name FROM widgets WHERE quantity > 100"
        console.currentDatabaseHint = "mysqlmacclient_test"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertTrue(console.isShowingQueryResult)
        XCTAssertEqual(console.queryResultColumns, ["name"])
        XCTAssertEqual(console.queryResultRows.map { $0.originalValues["name"]?.displayString }, ["Nut"])
    }

    func testRunQueryExecutesOnlySelectionWhenOneExists() async throws {
        let console = makeConsole()
        console.currentDatabaseHint = "mysqlmacclient_test"

        // The full editor holds a destructive UPDATE; the selection is a
        // harmless SELECT. Only the selection may run.
        console.queryText = "UPDATE widgets SET quantity = 42 WHERE name = 'Bolt'"
        console.querySelectedText = "SELECT name FROM widgets WHERE name = 'Nut'"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertEqual(console.queryResultColumns, ["name"])
        XCTAssertEqual(console.queryResultRows.map { $0.originalValues["name"]?.displayString }, ["Nut"])

        let rows = try await service.query("SELECT quantity FROM widgets WHERE name = 'Bolt'")
        XCTAssertEqual(rows.first?.column("quantity")?.int, 100, "editördeki UPDATE çalışmamalıydı")
    }

    func testRunQueryFallsBackToFullTextWhenSelectionIsEmpty() async throws {
        let console = makeConsole()
        console.currentDatabaseHint = "mysqlmacclient_test"

        console.queryText = "SELECT name FROM widgets WHERE quantity > 100"
        console.querySelectedText = "   "
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertEqual(console.queryResultRows.map { $0.originalValues["name"]?.displayString }, ["Nut"])
    }

    func testRunQueryUpdateShowsAffectedRowMessageAndAppliesTheWrite() async throws {
        let console = makeConsole()

        console.queryText = "UPDATE widgets SET quantity = 42 WHERE name = 'Bolt'"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertFalse(console.isShowingQueryResult)
        XCTAssertEqual(console.queryMessage, SQLConsoleViewModel.affectedRowsMessage(1))

        let rows = try await service.query("SELECT quantity FROM widgets WHERE name = 'Bolt'")
        XCTAssertEqual(rows.first?.column("quantity")?.int, 42)
    }

    func testRunQueryBadSqlSurfacesErrorWithoutCrashing() async throws {
        let console = makeConsole()

        console.queryText = "SELEKT * FROM widgets"
        await console.runQuery()

        XCTAssertNotNil(console.queryErrorMessage)
        XCTAssertFalse(console.isShowingQueryResult)
    }

    func testClearQueryResultInvokesOnQueryResultClearedSoTheGridRefreshes() async throws {
        // Simulates what `TableDataGridView` wires up: the console doesn't
        // know about any specific table's view model directly, only about
        // a closure the view layer points at that table's `reload()`.
        let console = makeConsole()
        console.currentDatabaseHint = "mysqlmacclient_test"
        let tableViewModel = TableDataViewModel(databaseName: "mysqlmacclient_test", tableName: "widgets", service: service, introspection: introspection)
        await tableViewModel.load()
        console.onQueryResultCleared = { await tableViewModel.reload() }

        console.queryText = "UPDATE widgets SET quantity = 7 WHERE name = 'Nut'"
        await console.runQuery()
        XCTAssertNil(console.queryErrorMessage)

        await console.clearQueryResult()

        XCTAssertFalse(console.isShowingQueryResult)
        XCTAssertEqual(
            tableViewModel.rows.first { $0.originalValues["name"]?.displayString == "Nut" }?.originalValues["quantity"]?.displayString,
            "7",
            "onQueryResultCleared çağrılmalı ve tablo grid'i yenilemeli"
        )
    }

    func testSimpleSingleTableSelectWithPrimaryKeyBecomesEditable() async throws {
        let console = makeConsole()
        console.currentDatabaseHint = "mysqlmacclient_test"
        console.isQueryResultEditableRequested = true

        console.queryText = "SELECT id, name, quantity FROM widgets WHERE name = 'Bolt'"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertNotNil(console.queryEditContext)
        XCTAssertTrue(console.isQueryResultEditable)
        XCTAssertNil(console.queryResultEditabilityNote)
    }

    func testQueryMissingPrimaryKeyColumnStaysReadOnlyEvenWhenEditableRequested() async throws {
        let console = makeConsole()
        console.currentDatabaseHint = "mysqlmacclient_test"
        console.isQueryResultEditableRequested = true

        // No `id` column selected, so there's nothing to build a WHERE from.
        console.queryText = "SELECT name, quantity FROM widgets"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertNil(console.queryEditContext)
        XCTAssertFalse(console.isQueryResultEditable)
        XCTAssertNotNil(console.queryResultEditabilityNote)
    }

    func testQueryMissingPrimaryKeyColumnStaysReadOnlyWithNoCurrentDatabaseHint() async throws {
        // Same as above, but with no table (and so no schema hint)
        // selected at all — an unqualified table name can't resolve to
        // anything, so this stays read-only rather than guessing wrong.
        let console = makeConsole()
        console.isQueryResultEditableRequested = true

        console.queryText = "SELECT name, quantity FROM widgets"
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertNil(console.queryEditContext)
        XCTAssertFalse(console.isQueryResultEditable)
    }

    func testJoinQueryStaysReadOnlyEvenWhenEditableRequested() async throws {
        let console = makeConsole()
        console.currentDatabaseHint = "mysqlmacclient_test"
        console.isQueryResultEditableRequested = true

        console.queryText = """
            SELECT w.id, w.name, l.message FROM widgets w
            JOIN widget_logs_nopk l ON l.widget_id = w.id
            """
        await console.runQuery()

        XCTAssertNil(console.queryErrorMessage)
        XCTAssertNil(console.queryEditContext)
        XCTAssertFalse(console.isQueryResultEditable)
    }

    func testCommitQueryResultEditUpdatesOnlyTheChangedColumnInTheDatabase() async throws {
        let console = makeConsole()
        console.currentDatabaseHint = "mysqlmacclient_test"
        console.isQueryResultEditableRequested = true

        console.queryText = "SELECT id, name, quantity, notes FROM widgets WHERE name = 'Bolt'"
        await console.runQuery()
        guard let row = console.queryResultRows.first else { return XCTFail("expected a result row") }

        await console.commitQueryResultEdit(rowId: row.id, column: "quantity", newText: "321")
        XCTAssertNil(console.queryErrorMessage)

        let check = try await service.query("SELECT quantity, notes FROM widgets WHERE id = 1")
        XCTAssertEqual(check.first?.column("quantity")?.int, 321)
        XCTAssertEqual(check.first?.column("notes")?.string, "Standard bolt")
    }

    func testDeleteQueryResultRowRemovesFromDatabaseAndRefreshesResults() async throws {
        let console = makeConsole()
        console.currentDatabaseHint = "mysqlmacclient_test"
        console.isQueryResultEditableRequested = true

        console.queryText = "SELECT id, name FROM widgets"
        await console.runQuery()
        guard let washer = console.queryResultRows.first(where: { $0.originalValues["name"]?.displayString == "Washer" }) else {
            return XCTFail("expected seed row missing")
        }

        await console.deleteQueryResultRow(washer)
        XCTAssertNil(console.queryErrorMessage)

        let check = try await service.query("SELECT COUNT(*) AS cnt FROM widgets")
        XCTAssertEqual(check.first?.column("cnt")?.int, 2)
        XCTAssertFalse(console.queryResultRows.contains { $0.originalValues["name"]?.displayString == "Washer" })
    }

    func testEditableToggleOffMakesQueryResultReadOnlyEvenWithAQualifyingQuery() async throws {
        let console = makeConsole()
        console.currentDatabaseHint = "mysqlmacclient_test"
        console.isQueryResultEditableRequested = false

        console.queryText = "SELECT id, name FROM widgets"
        await console.runQuery()

        XCTAssertNotNil(console.queryEditContext, "the query itself still qualifies")
        XCTAssertFalse(console.isQueryResultEditable, "but editing wasn't requested")
    }
}
