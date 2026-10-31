import SwiftUI

/// One "Oluştur ▸ <kind>..." request that only needs a name — drives the
/// shared `CreateNamedSchemaObjectView` sheet. Add a case here (plus one
/// arm in `MainWindowView`'s sheet closure) for each new kind instead of a
/// new `@State` pair.
private struct NamedObjectCreationRequest: Identifiable {
    enum Kind {
        case view, storedProcedure, function, trigger, event

        var title: String {
            switch self {
            case .view: return String(localized: "New View")
            case .storedProcedure: return String(localized: "New Stored Procedure")
            case .function: return String(localized: "New Function")
            case .trigger: return String(localized: "New Trigger")
            case .event: return String(localized: "New Event")
            }
        }

        var nameFieldLabel: String {
            switch self {
            case .view: return String(localized: "View Name")
            case .storedProcedure: return String(localized: "Stored Procedure Name")
            case .function: return String(localized: "Function Name")
            case .trigger: return String(localized: "Trigger Name")
            case .event: return String(localized: "Event Name")
            }
        }

        func sql(database: String, name: String) -> String {
            switch self {
            case .view: return SQLTemplate.createView(database: database, name: name)
            case .storedProcedure: return SQLTemplate.createStoredProcedure(database: database, name: name)
            case .function: return SQLTemplate.createFunction(database: database, name: name)
            case .trigger: return SQLTemplate.createTrigger(database: database, name: name)
            case .event: return SQLTemplate.createEvent(database: database, name: name)
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let database: String
}

/// Every "Drop X?" confirmation dialog (plus the shared context-action error
/// alert) pulled out of `MainWindowView.body` into its own `ViewModifier`.
/// Adding the trigger/event drop dialogs alongside table/view/routine's
/// pushed the whole chained `.confirmationDialog(...)` sequence past what
/// the type checker will resolve inline as part of `body`'s single
/// expression — this gives that sequence its own boundary instead.
private struct DropConfirmations: ViewModifier {
    @Binding var tablePendingTruncate: TableInfo?
    @Binding var tablePendingDrop: TableInfo?
    @Binding var routinePendingDrop: RoutineInfo?
    @Binding var triggerPendingDrop: TriggerInfo?
    @Binding var eventPendingDrop: EventInfo?
    @Binding var contextActionError: String?
    let onTruncateTable: (TableInfo) -> Void
    let onDropTable: (TableInfo) -> Void
    let onDropRoutine: (RoutineInfo) -> Void
    let onDropTrigger: (TriggerInfo) -> Void
    let onDropEvent: (EventInfo) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete ALL rows in '\(tablePendingTruncate?.name ?? "")'?",
                isPresented: Binding(
                    get: { tablePendingTruncate != nil },
                    set: { if !$0 { tablePendingTruncate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Truncate", role: .destructive) {
                    if let table = tablePendingTruncate {
                        onTruncateTable(table)
                    }
                    tablePendingTruncate = nil
                }
                Button("Cancel", role: .cancel) { tablePendingTruncate = nil }
            } message: {
                Text("TRUNCATE TABLE cannot be undone.")
            }
            .confirmationDialog(
                tablePendingDrop?.isView == true
                    ? "Permanently delete the view '\(tablePendingDrop?.name ?? "")'?"
                    : "Permanently delete the table '\(tablePendingDrop?.name ?? "")'?",
                isPresented: Binding(
                    get: { tablePendingDrop != nil },
                    set: { if !$0 { tablePendingDrop = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Drop", role: .destructive) {
                    if let table = tablePendingDrop {
                        onDropTable(table)
                    }
                    tablePendingDrop = nil
                }
                Button("Cancel", role: .cancel) { tablePendingDrop = nil }
            } message: {
                Text(
                    tablePendingDrop?.isView == true
                        ? "DROP VIEW deletes the view permanently and cannot be undone."
                        : "DROP TABLE deletes the table and its structure permanently and cannot be undone."
                )
            }
            .confirmationDialog(
                "Permanently delete the \(routinePendingDrop?.kind.displayName ?? "") '\(routinePendingDrop?.name ?? "")'?",
                isPresented: Binding(
                    get: { routinePendingDrop != nil },
                    set: { if !$0 { routinePendingDrop = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Drop", role: .destructive) {
                    if let routine = routinePendingDrop {
                        onDropRoutine(routine)
                    }
                    routinePendingDrop = nil
                }
                Button("Cancel", role: .cancel) { routinePendingDrop = nil }
            } message: {
                Text("DROP \(routinePendingDrop?.kind.sqlKeyword ?? "") deletes it permanently and cannot be undone.")
            }
            .modifier(TriggerEventDropConfirmations(
                triggerPendingDrop: $triggerPendingDrop,
                eventPendingDrop: $eventPendingDrop,
                contextActionError: $contextActionError,
                onDropTrigger: onDropTrigger,
                onDropEvent: onDropEvent
            ))
    }
}

/// Split out of `DropConfirmations` for the same type-checking-budget
/// reason — the shared error `.alert` lives here too since it has to sit
/// somewhere in this chain, and this is the tail end of it.
private struct TriggerEventDropConfirmations: ViewModifier {
    @Binding var triggerPendingDrop: TriggerInfo?
    @Binding var eventPendingDrop: EventInfo?
    @Binding var contextActionError: String?
    let onDropTrigger: (TriggerInfo) -> Void
    let onDropEvent: (EventInfo) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Permanently delete the \(String(localized: "Trigger")) '\(triggerPendingDrop?.name ?? "")'?",
                isPresented: Binding(
                    get: { triggerPendingDrop != nil },
                    set: { if !$0 { triggerPendingDrop = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Drop", role: .destructive) {
                    if let trigger = triggerPendingDrop {
                        onDropTrigger(trigger)
                    }
                    triggerPendingDrop = nil
                }
                Button("Cancel", role: .cancel) { triggerPendingDrop = nil }
            } message: {
                Text("DROP TRIGGER deletes it permanently and cannot be undone.")
            }
            .confirmationDialog(
                "Permanently delete the \(String(localized: "Event")) '\(eventPendingDrop?.name ?? "")'?",
                isPresented: Binding(
                    get: { eventPendingDrop != nil },
                    set: { if !$0 { eventPendingDrop = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Drop", role: .destructive) {
                    if let event = eventPendingDrop {
                        onDropEvent(event)
                    }
                    eventPendingDrop = nil
                }
                Button("Cancel", role: .cancel) { eventPendingDrop = nil }
            } message: {
                Text("DROP EVENT deletes it permanently and cannot be undone.")
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { contextActionError != nil },
                    set: { if !$0 { contextActionError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { contextActionError = nil }
            } message: {
                Text(contextActionError ?? "")
            }
    }
}

struct MainWindowView: View {
    let session: AppSession
    let onDisconnect: () -> Void

    /// Observed for the toolbar icon size — the store is injected at the
    /// app root, this view just needs to redraw when it changes.
    @EnvironmentObject private var settingsStore: SettingsStore

    @StateObject private var schemaTreeViewModel: SchemaTreeViewModel
    @StateObject private var insertionBridge = SQLInsertionBridge()
    /// One SQL console for the whole session — shared by every table's
    /// grid and by the no-table-selected placeholder, so the editor is
    /// always reachable even in a brand-new, still-empty database (see the
    /// split-view/`onQueryResultCleared` wiring below for why this had to
    /// move up from being per-table state).
    @StateObject private var console: SQLConsoleViewModel
    @State private var selectedTable: TableInfo?
    /// The sidebar's highlighted database — set by clicking a database row
    /// directly, and dragged along by `TableListView` whenever
    /// `selectedTable` moves. Owned here (rather than inside
    /// `TableListView`, where it used to live) because it's what feeds
    /// `console.currentDatabaseHint`: see the `onChange` below.
    @State private var selectedDatabaseName: String?
    @State private var isShowingCreateTable = false
    @State private var isShowingCreateDatabase = false
    /// Set when the create-table sheet is opened from a table's context
    /// menu, so the form pre-selects that table's database instead of the
    /// currently selected one.
    @State private var createTableDefaultDatabase: String?
    /// Drives the single generic "ask for a name" sheet shared by every
    /// "Oluştur ▸ <kind>..." menu item that's just a name prompt (View,
    /// Stored Procedure, Function so far) — one `@State` instead of a
    /// growing set of `isShowingCreateX`/`createXDatabase` pairs.
    @State private var namedObjectCreationRequest: NamedObjectCreationRequest?
    @State private var tablePendingTruncate: TableInfo?
    @State private var tablePendingDrop: TableInfo?
    @State private var tableToAlter: TableInfo?
    @State private var tableToExport: TableInfo?
    @State private var tableToImport: TableInfo?
    @State private var databaseToBackUp: DatabaseInfo?
    @State private var databaseToRestore: DatabaseInfo?
    @State private var routinePendingDrop: RoutineInfo?
    @State private var triggerPendingDrop: TriggerInfo?
    @State private var eventPendingDrop: EventInfo?
    @State private var contextActionError: String?
    /// Surfaced from the selected table's grid up to `StatusBarView` — see
    /// `TableDataGridView`'s `onRowCountChange`. `nil` with nothing selected
    /// (or before its first load completes).
    @State private var selectedTableRowCount: Int?

    /// One recorder for everything this window runs on the user's behalf
    /// (truncate/drop here, plus the grid and form view models below).
    private var historyRecorder: QueryHistoryRecorder {
        QueryHistoryRecorder(store: .shared, profileID: session.profile.id)
    }

    private static let minPanelHeight: CGFloat = 180
    private static let minGridHeight: CGFloat = 150
    @State private var queryPanelHeight: CGFloat = Self.minPanelHeight
    @State private var dragStartHeight: CGFloat?

    init(session: AppSession, onDisconnect: @escaping () -> Void) {
        self.session = session
        self.onDisconnect = onDisconnect
        _schemaTreeViewModel = StateObject(
            wrappedValue: SchemaTreeViewModel(introspection: session.introspectionService)
        )
        _console = StateObject(
            wrappedValue: SQLConsoleViewModel(
                service: session.mysqlService,
                introspection: session.introspectionService,
                historyRecorder: QueryHistoryRecorder(store: .shared, profileID: session.profile.id)
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebarTree
                    .navigationSplitViewColumnWidth(min: 200, ideal: 260)
            } detail: {
                detailPane
            }

            StatusBarView(profile: session.profile, rowCount: selectedTableRowCount, onDisconnect: onDisconnect)
        }
        .task {
            await schemaTreeViewModel.loadDatabases()
        }
        // The console's "what schema does an unqualified name mean" guess
        // follows the sidebar's highlighted *database*, not the selected
        // table: a database row can be selected with no table under it
        // chosen (a freshly opened database, or one whose tables the user
        // hasn't clicked into), and pasted unqualified SQL has to work
        // there too. `TableListView` keeps this in step with `selectedTable`,
        // so table selections still move the hint — via this one path.
        .onChange(of: selectedDatabaseName) { _, newValue in
            console.currentDatabaseHint = newValue
        }
        .onChange(of: selectedTable) { _, newValue in
            // Drops the no-longer-relevant table-grid reload hookup once
            // nothing is selected (see
            // `SQLConsoleViewModel.onQueryResultCleared`).
            if newValue == nil {
                console.onQueryResultCleared = nil
                selectedTableRowCount = nil
            } else if console.isShowingQueryResult {
                // Selecting a *different* table while a query's results are
                // still on screen: `TableDataGridView` checks
                // `isShowingQueryResult` before its own grid, so without
                // this the newly selected table kept showing the previous
                // query's stale rows instead of its own data. Synchronous
                // reset, not `clearQueryResult()` — that one also awaits
                // `onQueryResultCleared`, which races the new table's own
                // `.task(id:)` load and crashed mysql-nio with two
                // concurrent queries on one connection.
                console.resetQueryResultForTableSwitch()
            }
        }
        .onChange(of: insertionBridge.pendingText) { _, newValue in
            guard let text = newValue else { return }
            console.isQueryPanelVisible = true
            console.pendingQueryInsertion = text
            insertionBridge.pendingText = nil
        }
        .onChange(of: insertionBridge.pendingAppend) { _, newValue in
            guard let text = newValue else { return }
            console.isQueryPanelVisible = true
            console.pendingQueryAppend = text
            insertionBridge.pendingAppend = nil
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    createTableDefaultDatabase = nil
                    isShowingCreateTable = true
                } label: {
                    Label {
                        Text("New Table")
                    } icon: {
                        Image.bundled(
                            "create_table",
                            fallbackSystemImage: "rectangle.badge.plus",
                            pointSize: settingsStore.settings.general.toolbarIconSize
                        )
                    }
                }
                .help("Create New Table")
            }
            ToolbarItem(placement: .navigation) {
                SettingsLink {
                    Label {
                        Text("Settings")
                    } icon: {
                        Image.bundled(
                            "settings",
                            fallbackSystemImage: "gearshape",
                            pointSize: settingsStore.settings.general.toolbarIconSize
                        )
                    }
                }
                .help("Settings (⌘,)")
            }
            ToolbarItem(placement: .navigation) {
                QueryHistoryMenu(console: console)
            }
            ToolbarItem(placement: .primaryAction) {
                AppearancePickerView()
            }
        }
        .sheet(isPresented: $isShowingCreateTable) {
            CreateTableView(
                service: session.mysqlService,
                schemaTree: schemaTreeViewModel,
                defaultDatabase: createTableDefaultDatabase
                    ?? selectedTable?.database
                    ?? schemaTreeViewModel.databaseNodes.first?.info.name
                    ?? "",
                historyRecorder: historyRecorder
            ) { createdTable in
                Task {
                    if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == createdTable.database }) {
                        await node.reload()
                    }
                    selectedTable = createdTable
                }
            }
        }
        .sheet(isPresented: $isShowingCreateDatabase) {
            CreateDatabaseView(
                service: session.mysqlService,
                historyRecorder: historyRecorder
            ) { _ in
                Task { await schemaTreeViewModel.loadDatabases() }
            }
        }
        .sheet(item: $namedObjectCreationRequest) { request in
            CreateNamedSchemaObjectView(
                title: request.kind.title,
                nameFieldLabel: request.kind.nameFieldLabel,
                database: request.database
            ) { name in
                console.isQueryPanelVisible = true
                console.pendingQueryAppend = request.kind.sql(database: request.database, name: name)
            }
        }
        .sheet(item: $tableToAlter) { table in
            AlterTableView(
                service: session.mysqlService,
                table: table,
                historyRecorder: historyRecorder
            ) { alteredTable in
                Task {
                    if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == alteredTable.database }) {
                        await node.reload()
                    }
                    // Bounce the selection so the grid rebuilds with the new
                    // schema even when the table kept its name (same
                    // reasoning as the truncate refresh below).
                    selectedTable = nil
                    try? await Task.sleep(for: .milliseconds(50))
                    selectedTable = alteredTable
                }
            }
        }
        .sheet(item: $tableToExport) { table in
            TableExportView(service: session.mysqlService, table: table)
        }
        .sheet(item: $tableToImport) { table in
            TableImportView(service: session.mysqlService, table: table)
        }
        .sheet(item: $databaseToBackUp) { database in
            DatabaseBackupView(service: session.mysqlService, database: database)
        }
        .sheet(item: $databaseToRestore) { database in
            DatabaseRestoreView(service: session.mysqlService, database: database)
        }
        .modifier(DropConfirmations(
            tablePendingTruncate: $tablePendingTruncate,
            tablePendingDrop: $tablePendingDrop,
            routinePendingDrop: $routinePendingDrop,
            triggerPendingDrop: $triggerPendingDrop,
            eventPendingDrop: $eventPendingDrop,
            contextActionError: $contextActionError,
            onTruncateTable: { table in Task { await truncateTable(table) } },
            onDropTable: { table in Task { await dropTable(table) } },
            onDropRoutine: { routine in Task { await dropRoutine(routine) } },
            onDropTrigger: { trigger in Task { await dropTrigger(trigger) } },
            onDropEvent: { event in Task { await dropEvent(event) } }
        ))
    }

    /// Pulled out of `body` — `TableListView`'s growing closure list (now
    /// 22, one Alter/Drop or Create pair per object kind) pushed the whole
    /// `NavigationSplitView` past what the type checker will resolve inline;
    /// splitting it into its own typed property gives it a boundary to stop
    /// at instead of folding into `body`'s single expression.
    private var sidebarTree: some View {
        TableListView(
            viewModel: schemaTreeViewModel,
            selectedTable: $selectedTable,
            selectedDatabaseName: $selectedDatabaseName,
            insertionBridge: insertionBridge,
            profile: session.profile,
            onCreateDatabase: { isShowingCreateDatabase = true },
            onCreateTable: { database in
                createTableDefaultDatabase = database
                isShowingCreateTable = true
            },
            onCreateView: { database in
                namedObjectCreationRequest = NamedObjectCreationRequest(kind: .view, database: database)
            },
            onCreateStoredProcedure: { database in
                namedObjectCreationRequest = NamedObjectCreationRequest(kind: .storedProcedure, database: database)
            },
            onCreateFunction: { database in
                namedObjectCreationRequest = NamedObjectCreationRequest(kind: .function, database: database)
            },
            onCreateTrigger: { database in
                namedObjectCreationRequest = NamedObjectCreationRequest(kind: .trigger, database: database)
            },
            onCreateEvent: { database in
                namedObjectCreationRequest = NamedObjectCreationRequest(kind: .event, database: database)
            },
            onBackupDatabase: { databaseToBackUp = $0 },
            onRestoreDatabase: { databaseToRestore = $0 },
            onTruncateTable: { tablePendingTruncate = $0 },
            onDropTable: { tablePendingDrop = $0 },
            onInsertQueryTemplate: { table, kind in
                Task { await insertQueryTemplate(for: table, kind: kind) }
            },
            onAlterTable: { tableToAlter = $0 },
            onExportTable: { tableToExport = $0 },
            onImportTable: { tableToImport = $0 },
            onShowTableInfo: { table in
                selectedTable = table
                insertionBridge.pendingShowInfo = true
            },
            onAlterView: { view in
                Task { await alterView(view) }
            },
            onDropView: { tablePendingDrop = $0 },
            onAlterRoutine: { routine in
                Task { await alterRoutine(routine) }
            },
            onDropRoutine: { routinePendingDrop = $0 },
            onAlterTrigger: { trigger in
                Task { await alterTrigger(trigger) }
            },
            onDropTrigger: { triggerPendingDrop = $0 },
            onAlterEvent: { event in
                Task { await alterEvent(event) }
            },
            onDropEvent: { eventPendingDrop = $0 }
        )
    }

    /// The SQL console (when open) sits above whichever content follows —
    /// a selected table's grid, or the placeholder — with a draggable
    /// divider between them. Hoisted here (rather than living inside
    /// `TableDataGridView`) so it's reachable with *no* table selected at
    /// all, which is exactly the case a brand-new empty database needs:
    /// nothing in the sidebar to select yet, but the editor still has to
    /// be reachable to run a first `CREATE TABLE`.
    ///
    /// Deliberately not a `VSplitView`: `VSplitView` decides pane heights
    /// itself when a pane first appears, and it repeatedly opened the
    /// query panel squeezed below its content's real minimum no matter
    /// what min/ideal frames the pane declared. Owning the height in
    /// `@State` and applying it as an exact `.frame(height:)` makes a
    /// squeezed first layout impossible, at the cost of hand-rolling the
    /// divider drag.
    private var detailPane: some View {
        GeometryReader { geometry in
            // Explicit `.leading` + an explicit full-width frame on the
            // query panel: `VStack`'s default `.center` alignment let the
            // panel drift sideways at narrow widths, sized to whichever
            // child briefly reported the largest natural width instead of
            // staying pinned to the leading edge.
            VStack(alignment: .leading, spacing: 0) {
                if console.isQueryPanelVisible {
                    QueryPanelView(console: console)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: clampedPanelHeight(totalHeight: geometry.size.height))

                    splitDivider(totalHeight: geometry.size.height)
                }

                Group {
                    if let selectedTable {
                        TableDataGridView(
                            databaseName: selectedTable.database,
                            tableName: selectedTable.name,
                            service: session.mysqlService,
                            introspection: session.introspectionService,
                            console: console,
                            insertionBridge: insertionBridge,
                            historyRecorder: historyRecorder,
                            onRowCountChange: { selectedTableRowCount = $0 }
                        )
                        .id(selectedTable.id)
                    } else {
                        emptyStatePlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Shown when nothing is selected in the sidebar. Still honors the
    /// console's query results — running a `SELECT` with no table open
    /// works exactly like it does with one open — so this isn't just a
    /// dead end while the sidebar is empty.
    private var emptyStatePlaceholder: some View {
        Group {
            if console.isShowingQueryResult {
                QueryResultTabbedView(console: console)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Select a table")
                        .foregroundStyle(.secondary)

                    Button {
                        console.toggleQueryPanel()
                    } label: {
                        Label(console.isQueryPanelVisible ? "Hide SQL Query" : "Run SQL Query", systemImage: "terminal")
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The panel never renders below its content's real minimum, and
    /// whatever's below (grid or placeholder) always keeps at least
    /// `minGridHeight` — whichever way the user drags or the window
    /// resizes.
    private func clampedPanelHeight(totalHeight: CGFloat) -> CGFloat {
        let maxAllowed = max(Self.minPanelHeight, totalHeight - Self.minGridHeight)
        return min(max(queryPanelHeight, Self.minPanelHeight), maxAllowed)
    }

    private func splitDivider(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .gridLineColor))
            .frame(height: 5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = clampedPanelHeight(totalHeight: totalHeight)
                        }
                        queryPanelHeight = (dragStartHeight ?? Self.minPanelHeight) + value.translation.height
                    }
                    .onEnded { _ in
                        queryPanelHeight = clampedPanelHeight(totalHeight: totalHeight)
                        dragStartHeight = nil
                    }
            )
    }

    /// "SQL Sorgu Ekle" context-menu action: fetches the table's real
    /// column list, builds the statement skeleton, and routes it through
    /// the insertion bridge. Deliberately does *not* change `selectedTable`
    /// — the statement is fully qualified with its own database/table
    /// name, so nothing needs the grid to jump there, and doing so used to
    /// switch whatever table's data was on screen to this one's the moment
    /// a template was picked, before the user ever pressed Run.
    private func insertQueryTemplate(for table: TableInfo, kind: SQLTemplate.Kind) async {
        let columns: [ColumnInfo]
        do {
            columns = try await session.introspectionService.columns(forTable: table.name, inDatabase: table.database)
        } catch {
            contextActionError = String(localized: "Could not load columns: \(error.localizedDescription)")
            return
        }

        insertionBridge.pendingAppend = SQLTemplate.generate(
            kind,
            database: table.database,
            table: table.name,
            columns: columns
        )
    }

    private func truncateTable(_ table: TableInfo) async {
        do {
            let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: table.database, name: table.name)
            let sql = "TRUNCATE TABLE \(qualified)"
            historyRecorder.record(sql, database: table.database, source: .app)
            try await session.mysqlService.execute(sql)
            AnalyticsService.trackFeatureUsed("truncate_table")
        } catch {
            contextActionError = String(localized: "Truncate failed: \(error.localizedDescription)")
            AnalyticsService.trackError(error, feature: "truncate_table")
            return
        }

        // The grid view's identity is keyed by `selectedTable.id`, which
        // doesn't change here — bouncing the selection through nil (across
        // two separate UI updates) is what forces a fresh grid that reloads
        // the now-empty table.
        if selectedTable?.id == table.id {
            selectedTable = nil
            try? await Task.sleep(for: .milliseconds(50))
            selectedTable = table
        }
    }

    private func dropTable(_ table: TableInfo) async {
        do {
            let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: table.database, name: table.name)
            let statement = table.isView ? "DROP VIEW \(qualified)" : "DROP TABLE \(qualified)"
            historyRecorder.record(statement, database: table.database, source: .app)
            try await session.mysqlService.execute(statement)
            AnalyticsService.trackFeatureUsed(table.isView ? "drop_view" : "drop_table")
        } catch {
            contextActionError = String(localized: "Drop failed: \(error.localizedDescription)")
            AnalyticsService.trackError(error, feature: table.isView ? "drop_view" : "drop_table")
            return
        }

        if selectedTable?.id == table.id {
            selectedTable = nil
        }
        if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == table.database }) {
            await node.reload()
        }
    }

    /// "Alter View" context-menu action: reads the view's real definition
    /// back off the server (rather than reconstructing it from whatever's
    /// in the sidebar, which only ever holds the name) and appends it,
    /// reformatted, to the query console for editing.
    private func alterView(_ view: TableInfo) async {
        let createView: String
        do {
            createView = try await session.introspectionService.showCreateView(view.name, inDatabase: view.database)
        } catch {
            contextActionError = String(localized: "Could not load view definition: \(error.localizedDescription)")
            return
        }

        insertionBridge.pendingAppend = ViewAlterStatement.format(
            database: view.database,
            view: view.name,
            createView: createView
        )
    }

    /// "Alter Procedure"/"Alter Function" context-menu action — same shape
    /// as `alterView`. MySQL's own `ALTER PROCEDURE`/`ALTER FUNCTION` can't
    /// change a routine's body (only characteristics like `COMMENT`/`SQL
    /// SECURITY`), so "altering" one always means drop-and-recreate; see
    /// `RoutineAlterStatement`.
    private func alterRoutine(_ routine: RoutineInfo) async {
        let createStatement: String
        do {
            createStatement = try await session.introspectionService.showCreateRoutine(routine)
        } catch {
            contextActionError = String(localized: "Could not load \(routine.kind.displayName) definition: \(error.localizedDescription)")
            return
        }

        insertionBridge.pendingAppend = RoutineAlterStatement.format(
            routine: routine,
            createStatement: createStatement
        )
    }

    private func dropRoutine(_ routine: RoutineInfo) async {
        do {
            let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: routine.database, name: routine.name)
            // `rawQuery`, not `execute` — `DROP PROCEDURE`/`DROP FUNCTION`
            // are rejected by the prepared-statement protocol
            // (`ER_UNSUPPORTED_PS`), and `rawQuery` is the one method that
            // already retries through the plain-text protocol when that
            // happens.
            let sql = "DROP \(routine.kind.sqlKeyword) \(qualified)"
            historyRecorder.record(sql, database: routine.database, source: .app)
            _ = try await session.mysqlService.rawQuery(sql)
        } catch {
            contextActionError = String(localized: "Drop failed: \(error.localizedDescription)")
            return
        }

        if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == routine.database }) {
            await node.reloadRoutines(routine.kind)
        }
    }

    /// "Alter Trigger" context-menu action — same shape as `alterRoutine`.
    /// MySQL has no `ALTER TRIGGER` at all, so "altering" one always means
    /// drop-and-recreate; see `TriggerAlterStatement`.
    private func alterTrigger(_ trigger: TriggerInfo) async {
        let createStatement: String
        do {
            createStatement = try await session.introspectionService.showCreateTrigger(trigger)
        } catch {
            let label = String(localized: "Trigger")
            contextActionError = String(localized: "Could not load \(label) definition: \(error.localizedDescription)")
            return
        }

        insertionBridge.pendingAppend = TriggerAlterStatement.format(
            trigger: trigger,
            createStatement: createStatement
        )
    }

    private func dropTrigger(_ trigger: TriggerInfo) async {
        do {
            let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: trigger.database, name: trigger.name)
            // `rawQuery`, not `execute` — same prepared-statement-protocol
            // rejection as `dropRoutine`.
            let sql = "DROP TRIGGER \(qualified)"
            historyRecorder.record(sql, database: trigger.database, source: .app)
            _ = try await session.mysqlService.rawQuery(sql)
        } catch {
            contextActionError = String(localized: "Drop failed: \(error.localizedDescription)")
            return
        }

        if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == trigger.database }) {
            await node.reloadTriggers()
        }
    }

    /// "Alter Event" context-menu action — same shape as `alterTrigger`.
    private func alterEvent(_ event: EventInfo) async {
        let createStatement: String
        do {
            createStatement = try await session.introspectionService.showCreateEvent(event)
        } catch {
            let label = String(localized: "Event")
            contextActionError = String(localized: "Could not load \(label) definition: \(error.localizedDescription)")
            return
        }

        insertionBridge.pendingAppend = EventAlterStatement.format(
            event: event,
            createStatement: createStatement
        )
    }

    private func dropEvent(_ event: EventInfo) async {
        do {
            let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: event.database, name: event.name)
            let sql = "DROP EVENT \(qualified)"
            historyRecorder.record(sql, database: event.database, source: .app)
            _ = try await session.mysqlService.rawQuery(sql)
        } catch {
            contextActionError = String(localized: "Drop failed: \(error.localizedDescription)")
            return
        }

        if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == event.database }) {
            await node.reloadEvents()
        }
    }
}
