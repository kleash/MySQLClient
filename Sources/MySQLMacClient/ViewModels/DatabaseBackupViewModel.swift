import AppKit
import Foundation
import MySQLNIO

/// Backs the "Backup..." sheet: independent of `SchemaTreeViewModel`/
/// `DatabaseNode` (the sidebar's lazy, one-category-at-a-time loading is
/// the wrong shape here — this dialog needs all four object categories
/// loaded together up front), same independence principle
/// `TableExportViewModel` already established for single-table export.
@MainActor
final class DatabaseBackupViewModel: ObservableObject {
    /// Progress is tracked in two units at once because they answer
    /// different questions: object counts say *what* is being worked on,
    /// while the percentage has to reflect actual work done. Counting only
    /// objects made the bar sit at 0% for minutes on end whenever one huge
    /// table dominated the run (a real 1.15M-row table took ~4 minutes as a
    /// single object), then jump straight to 100%.
    struct Progress: Equatable {
        var completedObjects: Int
        var totalObjects: Int
        /// Rows written so far, plus one unit per schema object emitted.
        var completedUnits: Int
        var totalUnits: Int
        var currentObjectDescription: String
        /// Clamped: a table can grow between the row count taken up front
        /// and the rows actually read, which would otherwise overshoot 1.0.
        var percentage: Double {
            guard totalUnits > 0 else { return 0 }
            return min(1, Double(completedUnits) / Double(totalUnits))
        }
    }

    enum BackupError: LocalizedError {
        case connectionLost

        var errorDescription: String? {
            String(localized: "The connection to the server dropped during the backup. The rest would have been read outside the backup's snapshot and settings, so nothing was saved. Run the backup again.")
        }
    }

    private enum BackupObject {
        case table(TableInfo)
        case view(TableInfo)
        case procedure(RoutineInfo)
        case function(RoutineInfo)
        case trigger(TriggerInfo)
        case event(EventInfo)

        var description: String {
            switch self {
            case .table(let table): return String(localized: "Table: \(table.name)")
            case .view(let view): return String(localized: "View: \(view.name)")
            case .procedure(let routine): return String(localized: "Procedure: \(routine.name)")
            case .function(let routine): return String(localized: "Function: \(routine.name)")
            case .trigger(let trigger): return String(localized: "Trigger: \(trigger.name)")
            case .event(let event): return String(localized: "Event: \(event.name)")
            }
        }
    }

    @Published private(set) var database: DatabaseInfo
    @Published private(set) var availableDatabases: [DatabaseInfo] = []

    @Published private(set) var allTables: [TableInfo] = []
    @Published private(set) var allViews: [TableInfo] = []
    @Published private(set) var allProcedures: [RoutineInfo] = []
    @Published private(set) var allFunctions: [RoutineInfo] = []
    /// In the order `SHOW TRIGGERS` lists them, which for the triggers of
    /// one table and event is the order they fire in.
    @Published private(set) var allTriggers: [TriggerInfo] = []
    @Published private(set) var allEvents: [EventInfo] = []

    @Published var selectedTables: Set<TableInfo> = []
    @Published var selectedViews: Set<TableInfo> = []
    @Published var selectedProcedures: Set<RoutineInfo> = []
    @Published var selectedFunctions: Set<RoutineInfo> = []
    @Published var selectedTriggers: Set<TriggerInfo> = []
    @Published var selectedEvents: Set<EventInfo> = []

    /// `LOCK TABLES` causes an implicit `COMMIT` in MySQL, which would
    /// silently end a `START TRANSACTION WITH CONSISTENT SNAPSHOT` running
    /// alongside it — real `mysqldump` treats `--lock-tables` and
    /// `--single-transaction` as alternatives, never both. Checking one
    /// here clears the other rather than letting the user pick a
    /// combination that quietly defeats itself.
    @Published var options = DatabaseBackupOptions() {
        didSet {
            guard options.source != oldValue.source else { return }
            if options.source.lockTablesForReading, !oldValue.source.lockTablesForReading {
                options.source.useSingleTransaction = false
            } else if options.source.useSingleTransaction, !oldValue.source.useSingleTransaction {
                options.source.lockTablesForReading = false
            }
        }
    }

    /// Back up with mysqldump (or mariadb-dump) instead of the built-in
    /// engine: always the whole database, with its options rather than the
    /// ones above (`ExternalTool.dumpArguments`).
    @Published var usesExternalTool = false
    /// The tool that runs then, found when the objects load; nil if there's none.
    @Published private(set) var externalToolURL: URL?
    /// mysqldump writes every value the way the server prints it, and
    /// MariaDB prints a FLOAT to 6 significant digits (16777216 as
    /// 16777200): there a FLOAT column wouldn't come back as it was.
    var externalToolRoundsFloats: Bool { serverIsMariaDB && hasFloatColumns }
    @Published private var hasFloatColumns = false

    @Published var outputFileURL: URL?
    /// Whether `outputFileURL` currently points at a location the sandbox
    /// has actually granted write access to — see the identical flag in
    /// `TableExportViewModel` for the full explanation. `defaultOutputURL()`
    /// is only a display guess; `startBackup()` forces the save panel to
    /// run at least once before ever attempting a write.
    /// Not `private`: tests set this directly alongside `outputFileURL` to
    /// bypass the real `NSSavePanel`, which can't run headless.
    var outputLocationIsGranted = false
    @Published private(set) var isLoadingObjects = true
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Progress?
    @Published var errorMessage: String?
    /// A non-blocking note from object loading — e.g. the routine catalog
    /// being unreadable while tables/views loaded fine. Kept separate from
    /// `errorMessage` so it can't be mistaken for (or overwritten by) a
    /// failure of the backup run itself.
    @Published private(set) var loadWarning: String?
    /// Flips to `true` once the file is genuinely, atomically on disk —
    /// after `AtomicFileWriter`'s commit inside `performBackup` succeeds,
    /// never on cancellation or failure — so the view can show a
    /// completion alert. A plain settable `@Published`, not `private(set)`:
    /// SwiftUI's `.alert(isPresented:)` needs a two-way binding and sets
    /// this back to `false` itself once the alert is dismissed.
    @Published var didFinishSuccessfully = false

    /// Zero in production (no behavior change); overridable only by the
    /// cancellation test, so it can deterministically catch a running
    /// backup mid-flight instead of racing a sub-millisecond dump against
    /// the tiny seed database.
    var interObjectDelay: Duration = .zero

    /// Rows fetched per round trip while dumping a table's data — see
    /// `dumpTableData`. Small enough that neither this process nor the
    /// server ever holds a whole large table at once, but sized against
    /// *network* cost rather than memory: page count is round-trip count,
    /// and against a remote server that latency dominates. A real 1.15M-row
    /// table took ~4 minutes at 1000 rows/page (1149 round trips); this
    /// cuts that to 230. Locally the two are indistinguishable (measured
    /// 17.4s vs 17.1s over 400k rows), so the win is purely for remote
    /// connections — which is the case that actually hurt.
    ///
    /// Settable so paging tests can force a boundary with a handful of
    /// rows instead of having to insert tens of thousands.
    var dataPageSize = 5000

    var selectedObjectCount: Int {
        selectedTables.count + selectedViews.count + selectedProcedures.count + selectedFunctions.count
            + selectedTriggers.count + selectedEvents.count
    }

    /// The connection everything is read through: the app's shared one
    /// while the dialog lists objects, and one of the backup's own while it
    /// runs (`performBackup`).
    private var service: MySQLService
    private var introspection: SchemaIntrospectionService { SchemaIntrospectionService(service: service) }
    private var backupTask: Task<Void, Never>?
    /// Progress bookkeeping for the run in flight — see `Progress`.
    private var totalUnits = 0
    private var unitsBeforeCurrentObject = 0
    private var wroteViewStandIns = false
    /// The database's default collation, read as a run begins — see
    /// `creationStatement`.
    private var databaseCollation = ""
    private var serverIsMariaDB = false
    /// Tables and views mysqldump has started on in the run in flight.
    private var externalObjectsStarted = 0

    init(service: MySQLService, database: DatabaseInfo) {
        self.service = service
        self.database = database
    }

    // MARK: - Loading

    /// Called from the sheet's `.task` on appearance.
    func loadDatabasesAndObjects() async {
        do {
            availableDatabases = try await introspection.listDatabases()
        } catch {
            // Non-fatal — the picker just falls back to the one database
            // already known, rather than ending up with nothing to show.
            availableDatabases = [database]
        }
        outputFileURL = defaultOutputURL()
        outputLocationIsGranted = false
        serverIsMariaDB = await service.serverVersion?.contains("MariaDB") ?? false
        externalToolURL = ExternalTool.locate(.dump, configuredPath: SettingsStore.shared.settings.general.dumpToolPath,
                                              preferMariaDB: serverIsMariaDB)
        await loadObjects()
    }

    /// Called when the VERİTABANI ADI picker changes. Re-suffixes the
    /// suggested filename the same way `TableExportViewModel` does for a
    /// format change — only when the current URL still looks
    /// auto-generated, so a path the user actually browsed to is left
    /// alone.
    func selectDatabase(_ newDatabase: DatabaseInfo) async {
        // Not mid-run: the rest of the backup would be read from the other
        // database.
        guard newDatabase != database, !isRunning else { return }
        let previousDefault = defaultOutputURL()
        database = newDatabase
        if outputFileURL == nil || outputFileURL == previousDefault {
            outputFileURL = defaultOutputURL()
        }
        await loadObjects()
    }

    /// Lists on a connection of its own when one opens, as the backup reads
    /// (`performBackup`): names come back in the session's character set,
    /// so after SET NAMES latin1 in the console one outside it (an emoji, a
    /// combining mark) would come back as '?', naming another object or none.
    private func loadObjects() async {
        isLoadingObjects = true
        defer { isLoadingObjects = false }
        let own = try? await service.openSeparateConnection()
        await listObjects(on: own ?? service)
        try? await own?.disconnect()
    }

    /// Tables/views and routines are fetched as two independent steps, not
    /// one all-or-nothing `async let` group — a server whose routine
    /// catalog is unreadable (a real thing that happens: an outdated
    /// `mysql.proc` after a MariaDB upgrade is exactly what this project's
    /// own local test server currently hits) must not block backing up
    /// tables and views just because Procedure'lar/Function'lar couldn't be
    /// listed. That failure degrades to two empty categories plus a
    /// non-blocking note, instead of an empty dialog with a single
    /// all-encompassing error.
    private func listObjects(on service: MySQLService) async {
        // The listing connection's, not the properties'.
        let introspection = SchemaIntrospectionService(service: service)
        errorMessage = nil
        loadWarning = nil

        do {
            let tablesAndViews = try await introspection.listTablesAndViews(inDatabase: database.name)
            allTables = tablesAndViews.filter { !$0.isView }
            allViews = tablesAndViews.filter(\.isView)
            selectedTables = Set(allTables)
            selectedViews = Set(allViews)
        } catch {
            errorMessage = describe(error)
            return
        }
        let floatColumns = try? await service.query(
            "SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = ? AND DATA_TYPE = 'float' LIMIT 1",
            [MySQLData(string: database.name)]
        )
        hasFloatColumns = !(floatColumns ?? []).isEmpty

        do {
            allProcedures = try await introspection.listRoutines(.procedure, inDatabase: database.name)
            allFunctions = try await introspection.listRoutines(.function, inDatabase: database.name)
            selectedProcedures = Set(allProcedures)
            selectedFunctions = Set(allFunctions)
        } catch {
            allProcedures = []
            allFunctions = []
            selectedProcedures = []
            selectedFunctions = []
            loadWarning = String(localized: "Could not load the procedure/function list; tables and views were loaded: \(describe(error))")
        }

        // Same reasoning, and triggers apart from events: listing events
        // takes the EVENT privilege, which a user who can read everything
        // else may lack.
        func noteListFailure(_ error: Error) {
            let warning = String(localized: "Could not load the trigger/event list; the other objects were loaded: \(describe(error))")
            loadWarning = [loadWarning, warning].compactMap { $0 }.joined(separator: "\n")
        }
        do {
            allTriggers = try await introspection.listTriggers(inDatabase: database.name)
            selectedTriggers = Set(allTriggers)
        } catch {
            allTriggers = []
            selectedTriggers = []
            noteListFailure(error)
        }
        do {
            allEvents = try await introspection.listEvents(inDatabase: database.name)
            selectedEvents = Set(allEvents)
        } catch {
            allEvents = []
            selectedEvents = []
            noteListFailure(error)
        }

        // A single transaction reads InnoDB tables from one snapshot, but
        // another engine's (Aria, MyISAM) as they are at each read, so a
        // backup could hold an order's items without the order.
        let notInnoDB = (try? await service.query(
            "SELECT TABLE_NAME AS name FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND ENGINE <> 'InnoDB' ORDER BY TABLE_NAME",
            [MySQLData(string: database.name)]
        ))?.compactMap { $0.column("name")?.string } ?? []
        if !notInnoDB.isEmpty {
            let note = String(localized: "Not InnoDB, so \"Single transaction\" can't read them from one snapshot (\"Lock tables for reading\" can): \(notInnoDB.joined(separator: ", "))")
            loadWarning = [loadWarning, note].compactMap { $0 }.joined(separator: "\n")
        }
    }

    func selectAllObjects() {
        selectedTables = Set(allTables)
        selectedViews = Set(allViews)
        selectedProcedures = Set(allProcedures)
        selectedFunctions = Set(allFunctions)
        selectedTriggers = Set(allTriggers)
        selectedEvents = Set(allEvents)
    }

    func selectNoObjects() {
        selectedTables = []
        selectedViews = []
        selectedProcedures = []
        selectedFunctions = []
        selectedTriggers = []
        selectedEvents = []
    }

    private func defaultOutputURL() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return desktop.appendingPathComponent(database.name).appendingPathExtension("sql")
    }

    // MARK: - File picker — identical pattern to TableExportViewModel.chooseOutputFile

    func chooseOutputFile() {
        let panel = NSSavePanel()
        let seed = outputFileURL ?? defaultOutputURL()
        panel.nameFieldStringValue = seed.lastPathComponent
        panel.directoryURL = seed.deletingLastPathComponent()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFileURL = url
        outputLocationIsGranted = true
    }

    // MARK: - Running the backup

    /// Owns its own `Task` rather than being launched from the view's own
    /// `Task { }` (unlike `TableExportView.runExport()`), because
    /// cancellation must be reachable from a *different* button ("Kapat")
    /// than the one that started it ("Aktar"). The strong `[self]` capture
    /// is deliberate: if the sheet is dismissed while running, the
    /// `@StateObject` could otherwise be torn down mid-write, skipping the
    /// file-handle-close/partial-file-delete cleanup in `performBackup`.
    func startBackup() {
        guard !isRunning else { return }
        // `outputFileURL` may still be just the auto-generated guess from
        // `loadDatabasesAndObjects()`, which the sandbox never actually
        // granted access to — force the save panel here so the write below
        // doesn't fail with a permission error. If the user cancels, bail
        // out entirely.
        if !outputLocationIsGranted {
            chooseOutputFile()
            guard outputLocationIsGranted else { return }
        }
        // Set synchronously, before the task is even scheduled: a `Task {}`
        // body doesn't necessarily begin running before control returns
        // here, so flipping this inside `performBackup` would leave a
        // window where `isRunning` is still false — long enough for a
        // second "Aktar" tap to start a competing backup over the same
        // output file.
        isRunning = true
        errorMessage = nil
        backupTask = Task { [self] in await performBackup() }
    }

    /// Called from "Kapat" while running. Doesn't block on completion —
    /// cancellation and its cleanup happen inside `performBackup` itself,
    /// which is allowed to keep running briefly after the sheet dismisses.
    func cancelBackup() {
        backupTask?.cancel()
    }

    /// `isRunning`/`errorMessage` are set by `startBackup()` before this is
    /// scheduled — see the note there.
    ///
    /// Routed entirely through `AtomicFileWriter`: nothing here opens
    /// `outputFileURL` directly. Previously this truncated the target with
    /// `FileManager.createFile` before writing a single byte and deleted it
    /// on any failure or cancellation — fine the first time a path is used,
    /// but destroyed a pre-existing file (a backup tool's most common
    /// case: overwriting yesterday's dump) the second. `AtomicFileWriter`
    /// writes to a temp sibling throughout and only replaces the real
    /// target on a clean finish, so a failed or cancelled run now leaves
    /// whatever was already there completely untouched.
    ///
    /// Reads on a connection of its own, so its transaction, locks and
    /// settings never reach the session the rest of the app shares: a grid
    /// edit saved meanwhile would run inside the backup's snapshot and
    /// settings, and its START TRANSACTION would commit whatever the user
    /// had left open there. That connection doesn't reconnect by itself, as
    /// a new session would have neither, so a drop fails the backup.
    private func performBackup() async {
        defer { isRunning = false; backupTask = nil }

        guard let outputFileURL else { return }
        // Before the backup's own connection: mysqldump opens its own.
        if usesExternalTool { return await backUpWithExternalTool(to: outputFileURL) }
        let shared = service
        var source: MySQLService?
        do {
            let connection = try await shared.openSeparateConnection()
            source = connection
            service = connection
            // In UTC and with an empty SQL mode, as mysqldump reads: TIMESTAMP
            // values come out in the session's time zone, and modes such as
            // `ANSI_QUOTES` change how `SHOW CREATE` writes a statement. The
            // file declares the same time zone (`writeHeader`).
            _ = try await connection.textQuery("SET SESSION time_zone = '+00:00', sql_mode = ''")
            databaseCollation = try await connection.textQuery("""
                SELECT DEFAULT_COLLATION_NAME AS collation FROM information_schema.SCHEMATA
                WHERE SCHEMA_NAME = '\(SQLExporter.escapeStringLiteral(database.name))'
                """).first?.column("collation")?.string ?? ""
            let objects = try await buildObjectPlan()
            let weights = try await unitWeights(for: objects)
            totalUnits = weights.reduce(0, +)
            unitsBeforeCurrentObject = 0
            wroteViewStandIns = false
            progress = Progress(
                completedObjects: 0, totalObjects: objects.count,
                completedUnits: 0, totalUnits: totalUnits,
                currentObjectDescription: ""
            )

            try await AtomicFileWriter.write(to: outputFileURL) { fileHandle in
                try await self.beginSourceSession()
                try await self.writeHeader(to: fileHandle)
                for (index, object) in objects.enumerated() {
                    try Task.checkCancellation()
                    self.progress = Progress(
                        completedObjects: index, totalObjects: objects.count,
                        completedUnits: self.unitsBeforeCurrentObject, totalUnits: self.totalUnits,
                        currentObjectDescription: object.description
                    )
                    try await self.dump(object, to: fileHandle)
                    if self.options.source.useSingleTransaction {
                        // Lets go of the metadata locks reading the object
                        // took, as mysqldump does after each table: otherwise
                        // DDL on it waits for the whole backup, and every
                        // other query on it waits behind that DDL. The
                        // snapshot stays.
                        _ = try await self.service.textQuery("ROLLBACK TO SAVEPOINT sp")
                    }
                    self.unitsBeforeCurrentObject += weights[index]
                    if self.interObjectDelay != .zero {
                        try await Task.sleep(for: self.interObjectDelay)
                    }
                }
                try Task.checkCancellation()
                try await self.writeFooter(to: fileHandle)
                self.progress = Progress(
                    completedObjects: objects.count, totalObjects: objects.count,
                    completedUnits: self.totalUnits, totalUnits: self.totalUnits,
                    currentObjectDescription: String(localized: "Completed")
                )
            }
            // Only reached once `AtomicFileWriter` has actually performed
            // its atomic replace — the file is genuinely on disk, not just
            // "the last statement inside the closure ran".
            didFinishSuccessfully = true
            AnalyticsService.trackFeatureUsed("db_backup")
        } catch is CancellationError {
            // User-initiated — not an error to surface.
        } catch MySQLError.closed {
            errorMessage = BackupError.connectionLost.errorDescription
            AnalyticsService.trackError(BackupError.connectionLost, feature: "db_backup")
        } catch {
            errorMessage = describe(error)
            AnalyticsService.trackError(error, feature: "db_backup")
        }
        // Also ends the backup's transaction and releases its locks.
        try? await source?.disconnect()
        service = shared
    }

    /// mysqldump writes straight into `AtomicFileWriter`'s temporary file,
    /// which replaces the destination only once mysqldump has ended with
    /// exit status 0; otherwise, or when cancelled, it's thrown away. Its
    /// `--verbose` lines name each table and view as it starts on it, which
    /// is what the progress counts.
    private func backUpWithExternalTool(to outputFileURL: URL) async {
        let total = allTables.count + allViews.count
        externalObjectsStarted = 0
        progress = Progress(completedObjects: 0, totalObjects: total, completedUnits: 0, totalUnits: total, currentObjectDescription: "")
        do {
            let tool = try await ExternalTool.find(.dump, configuredPath: SettingsStore.shared.settings.general.dumpToolPath,
                                                   preferMariaDB: serverIsMariaDB)
            externalToolURL = tool.url
            let connection = try await service.externalToolConnection()
            let arguments = try tool.dumpArguments(database: database.name, connection: connection)
            try await AtomicFileWriter.write(to: outputFileURL) { fileHandle in
                _ = try await tool.run(arguments, optionFile: connection.optionFile, output: fileHandle) { line in
                    let prefix = "-- Retrieving table structure for table "
                    guard line.hasPrefix(prefix), line.hasSuffix("...") else { return }
                    let name = String(line.dropFirst(prefix.count).dropLast(3))
                    Task { @MainActor in self.externalObjectStarted(name) }
                }
            }
            progress = Progress(completedObjects: total, totalObjects: total, completedUnits: total, totalUnits: total,
                                currentObjectDescription: String(localized: "Completed"))
            didFinishSuccessfully = true
            AnalyticsService.trackFeatureUsed("db_backup")
        } catch is CancellationError {
            // User-initiated — not an error to surface.
        } catch {
            errorMessage = describe(error)
            AnalyticsService.trackError(error, feature: "db_backup")
        }
    }

    /// Ignored once the run is over: a line's update can arrive after the
    /// final one.
    private func externalObjectStarted(_ name: String) {
        guard isRunning, let total = progress?.totalObjects else { return }
        externalObjectsStarted += 1
        let done = min(externalObjectsStarted - 1, total)
        progress = Progress(completedObjects: done, totalObjects: total, completedUnits: done, totalUnits: total,
                            currentObjectDescription: String(localized: "Table: \(name)"))
    }

    /// Tables first, with CREATE+DATA interleaved per table (not two
    /// passes — this is what makes "one table = one progress tick" work,
    /// and is safe because `FOREIGN_KEY_CHECKS=0` is on by default,
    /// matching real `mysqldump`'s own behavior), MariaDB sequences ahead of
    /// them: CREATE TABLE checks that a sequence a DEFAULT takes numbers
    /// from exists. Then routines, whose bodies aren't checked until they
    /// run. Views after both — `CREATE VIEW` genuinely requires the tables
    /// and functions it uses to exist, unlike a constraint that's just
    /// disabled by a flag — and after a stand-in for each view
    /// (`writeViewStandIns`). Then triggers — after every table's rows, as
    /// mysqldump does, so restoring the rows doesn't fire them (an audit
    /// trigger would write its rows a second time) — in the order they
    /// fire, and events last. Alphabetical otherwise, since a `Set` has no
    /// defined order and dump output needs to be deterministic across runs.
    private func buildObjectPlan() async throws -> [BackupObject] {
        let views = try await viewsInDependencyOrder()
        return selectedTables.sorted { ($0.isSequence ? 0 : 1, $0.name) < ($1.isSequence ? 0 : 1, $1.name) }.map { .table($0) }
            + selectedProcedures.sorted { $0.name < $1.name }.map { .procedure($0) }
            + selectedFunctions.sorted { $0.name < $1.name }.map { .function($0) }
            + views.map { .view($0) }
            + allTriggers.filter(selectedTriggers.contains).map { .trigger($0) }
            + selectedEvents.sorted { $0.name < $1.name }.map { .event($0) }
    }

    /// Each view after the views its definition names, so none is created
    /// on a stand-in (`writeViewStandIns`): the server decides whether a
    /// view can be updated when it's created, and one created on a stand-in
    /// never can be, nor take WITH CHECK OPTION. Alphabetical otherwise.
    /// Read under an empty SQL mode, a definition quotes every name in it,
    /// so a view it's built on appears as `` `name` ``; a column that shares
    /// a view's name only adds an order that isn't needed.
    private func viewsInDependencyOrder() async throws -> [TableInfo] {
        let views = selectedViews.sorted { $0.name < $1.name }
        guard options.mode != .dataOnly else { return views }
        var definitions: [TableInfo: String] = [:]
        for view in views {
            definitions[view] = try await introspection.showCreateView(view.name, inDatabase: database.name)
        }
        var ordered: [TableInfo] = []
        var visited: Set<TableInfo> = []
        func visit(_ view: TableInfo) {
            guard visited.insert(view).inserted else { return }
            for other in views where other != view && definitions[view, default: ""].contains(SQLExporter.quoted(other.name)) {
                visit(other)
            }
            ordered.append(view)
        }
        views.forEach(visit)
        return ordered
    }

    /// How much work each planned object represents, so the percentage
    /// tracks rows rather than object count. One unit per schema statement
    /// plus one per data row, which makes the three modes fall out
    /// naturally: structure-only weighs every object equally (there are no
    /// rows), data-only weighs purely by row count, and the combined mode
    /// mixes both.
    ///
    /// The `COUNT(*)` per table is one extra round trip each, paid once up
    /// front — negligible against a dump that reads every row anyway, and
    /// it's what buys a percentage that actually moves. It reads the whole
    /// table on the server, so a cancelled backup stops counting.
    private func unitWeights(for objects: [BackupObject]) async throws -> [Int] {
        var weights: [Int] = []
        weights.reserveCapacity(objects.count)
        for object in objects {
            try Task.checkCancellation()
            var weight = options.mode == .dataOnly ? 0 : 1
            if case .table(let table) = object, options.mode != .structureOnly {
                weight += (try? await rowCount(of: table)) ?? 0
            }
            weights.append(weight)
        }
        return weights
    }

    private func rowCount(of table: TableInfo) async throws -> Int {
        let qualifiedTable = try SchemaIntrospectionService.qualifiedIdentifier(database: database.name, name: table.name)
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM \(qualifiedTable)")
        return rows.first?.column("cnt")?.int ?? 0
    }

    // MARK: - Source session (LOCK TABLES / START TRANSACTION)

    /// Over the text protocol (`textQuery`), one round trip each: MariaDB
    /// refuses `LOCK TABLES`, `START TRANSACTION` and `SAVEPOINT` as
    /// prepared statements, which `rawQuery` would try first. Nothing here
    /// is undone at the end: closing the backup's connection
    /// (`performBackup`) ends the transaction and releases the locks.
    ///
    /// The snapshot is read at REPEATABLE READ, as mysqldump does: at READ
    /// COMMITTED, which some servers are set to, the server ignores WITH
    /// CONSISTENT SNAPSHOT with only a warning, and every read sees the
    /// latest commit. `performBackup` rolls back to the savepoint after each
    /// object.
    private func beginSourceSession() async throws {
        // Views as well, which can't be read unless they're locked too, and
        // by their full names: the connection's own database may be another
        // one, or none.
        let lockedNames = (selectedTables.map(\.name) + selectedViews.map(\.name)).sorted()
        if options.source.lockTablesForReading, !lockedNames.isEmpty {
            let lockList = try lockedNames.map { try SchemaIntrospectionService.qualifiedIdentifier(database: database.name, name: $0) + " READ" }
            _ = try await service.textQuery("LOCK TABLES \(lockList.joined(separator: ", "))")
        }
        if options.source.useSingleTransaction {
            _ = try await service.textQuery("SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            _ = try await service.textQuery("START TRANSACTION WITH CONSISTENT SNAPSHOT")
            _ = try await service.textQuery("SAVEPOINT sp")
        }
    }

    // MARK: - Header / footer

    /// Starts with the session settings the file's contents depend on, as
    /// mysqldump does, because the server it's restored on may be set up
    /// differently: the character set the file is written in, the time zone
    /// its TIMESTAMP values are in, and an SQL mode that keeps an explicit 0
    /// in an AUTO_INCREMENT column (instead of taking the next number), keeps
    /// a date that doesn't exist (2024-02-30, which a server allowing them
    /// holds) instead of storing a zero date, and clears modes that would
    /// change how the file reads, such as `NO_BACKSLASH_ESCAPES`.
    /// `writeFooter` puts them back.
    private func writeHeader(to fileHandle: FileHandle) async throws {
        var header = """
            SET NAMES utf8mb4;
            SET @OLD_TIME_ZONE = @@TIME_ZONE, TIME_ZONE = '+00:00';
            SET @OLD_SQL_MODE = @@SQL_MODE, SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO,ALLOW_INVALID_DATES';

            """
        if options.file.includeCreateDatabaseStatement {
            // The server's own statement, so the database comes back with its
            // default character set and collation, not the target server's.
            let createDatabase = try await introspection.showCreateDatabase(database.name)
            header += createDatabase.replacingOccurrences(of: "CREATE DATABASE ", with: "CREATE DATABASE IF NOT EXISTS ", options: .anchored) + ";\n"
        }
        if options.file.includeUseStatement {
            header += "USE \(SQLExporter.quoted(database.name));\n"
        }
        if options.file.setForeignKeyChecksToZero {
            header += "SET FOREIGN_KEY_CHECKS=0;\n"
        }
        header += "\n"
        try fileHandle.write(contentsOf: Data(header.utf8))
    }

    private func writeFooter(to fileHandle: FileHandle) async throws {
        var footer = ""
        if options.file.setForeignKeyChecksToZero {
            footer += "SET FOREIGN_KEY_CHECKS=1;\n"
        }
        footer += "SET SQL_MODE = @OLD_SQL_MODE;\nSET TIME_ZONE = @OLD_TIME_ZONE;\n"
        try fileHandle.write(contentsOf: Data(footer.utf8))
    }

    // MARK: - Per-object dump

    private func dump(_ object: BackupObject, to fileHandle: FileHandle) async throws {
        switch object {
        case .table(let table):
            try await dumpTable(table, to: fileHandle)
        case .view(let view):
            if !wroteViewStandIns, options.mode != .dataOnly {
                wroteViewStandIns = true
                try await writeViewStandIns(to: fileHandle)
            }
            try await dumpView(view, to: fileHandle)
        case .procedure(let routine), .function(let routine):
            try await dumpRoutine(routine, to: fileHandle)
        case .trigger(let trigger):
            try await dumpTrigger(trigger, to: fileHandle)
        case .event(let event):
            try await dumpEvent(event, to: fileHandle)
        }
    }

    private func dumpTable(_ table: TableInfo, to fileHandle: FileHandle) async throws {
        if options.mode != .dataOnly {
            if options.file.includeDropStatements {
                try fileHandle.write(contentsOf: Data((SQLExporter.dropTableStatement(table: table.name) + "\n").utf8))
            }
            let rawDDL = try await introspection.showCreateTable(table.name, inDatabase: database.name)
            let createSQL = SQLExporter.createTableStatement(rawShowCreateTable: rawDDL)
            try fileHandle.write(contentsOf: Data((createSQL + "\n\n").utf8))
        }
        // A sequence's definition (where it starts, its increment, cache)
        // is in its one row, as well as where it has got to: SHOW CREATE
        // TABLE gives every sequence the same CREATE TABLE.
        if options.mode != .structureOnly || table.isSequence {
            try await dumpTableData(table, to: fileHandle)
        }
    }

    /// Read one page at a time rather than the whole table in one query.
    ///
    /// MySQLNIO has no streaming API — a single un-LIMITed `SELECT` buffers
    /// every row in memory before returning, then this view model turns
    /// them into INSERT text. On a big table (a real one this hit: a
    /// multi-million-row address table) that footprint is enough to exhaust
    /// memory and have the server drop the connection mid-read — which in a
    /// debug build then trips MySQLNIO's own `assert(statementID == nil)` in
    /// `MySQLQueryCommand.deinit`, taking the whole app down. Paging keeps
    /// each round trip small and bounded, so neither side is ever asked to
    /// hold the entire table at once.
    ///
    /// Pages by **primary key** (`WHERE (pk) > (lastPage'sLastPk)`), not by
    /// `OFFSET`, whenever the table has one. `OFFSET n` makes the
    /// server walk and discard all n preceding rows on every single page, so
    /// dumping a whole table that way costs O(rows²) — measured on this
    /// project's own test server at 400k rows, the last page took 1.659s
    /// with `OFFSET` versus 0.038s with a key range, and the gap widens
    /// with size. A key range seeks straight into the index instead, which
    /// is what keeps a multi-million-row table (the real one that prompted
    /// this: ~1.15M rows) finishing in seconds rather than tens of minutes.
    /// The last key goes back to the server exactly as it came
    /// (`SQLExporter.sqlLiteral`): a rounded DATETIME(6) or DECIMAL key
    /// would ask for the same page again forever. A key that can't be
    /// sought from (one with an ENUM, SET or BIT column, or a generated
    /// column the SELECT leaves out) still orders the pages, with `OFFSET`:
    /// that order is unique and the index's own, so the server walks the
    /// index instead of sorting the table for every page.
    ///
    /// Ordering also makes paging *correct*, not just fast: `LIMIT` across
    /// separate queries has no row-order guarantee without an `ORDER BY`,
    /// so rows could otherwise repeat or vanish between pages. A table with
    /// no primary key is ordered by the bytes of every column, so only rows
    /// that are identical (and so interchangeable) can trade places — the
    /// slow path, but such tables are rare and typically small. Not by the
    /// columns themselves: their collation calls 'a', 'A', 'á' and 'a '
    /// equal, and rows tied that way traded places between pages, so some
    /// were written twice and others not at all.
    ///
    /// Columns are named rather than `SELECT *`, which leaves out
    /// invisible columns, and generated ones are skipped: the server
    /// computes them and refuses an INSERT that names them.
    private func dumpTableData(_ table: TableInfo, to fileHandle: FileHandle) async throws {
        let allColumns = try await introspection.columns(forTable: table.name, inDatabase: database.name)
        // shortcut: a MariaDB system-versioned table gives only its current
        // rows, and its row start and end columns are generated, so history
        // and row start times aren't kept (10.4 can't insert them back:
        // ERROR 1906; mysqldump leaves them out too); read them FOR
        // SYSTEM_TIME ALL and restore with system_versioning_insert_history
        // (10.11+) if they're needed.
        let columns = allColumns.filter { !$0.isGenerated }
        let qualifiedTable = try SchemaIntrospectionService.qualifiedIdentifier(database: database.name, name: table.name)
        // FLOAT is read as DOUBLE: the server prints a FLOAT with only six
        // significant digits (16777216 as 16777200), while the DOUBLE holds
        // its exact value, which converts back to the very same FLOAT.
        // Multiplied by 1 rather than added to 0, which turns -0 into 0.
        //
        // An ENUM or SET that declares '' is read as its number: as text
        // that member is '', the same as an ENUM's error value or a SET's
        // empty set. (A type that only looks as if it declares '' is read
        // as numbers too, which restore just as well.)
        //
        // shortcut: text in a character set other than UTF-8 is read
        // converted to utf8mb4, so a byte with no Unicode character (0x98 in
        // cp1251; latin1 has none) comes back as '?'; select such columns as
        // CAST(col AS BINARY) and write them as _charset X'..' if that data
        // turns up.
        let selectExpressions = columns.map { column in
            let type = column.mysqlType.lowercased()
            if type.hasPrefix("float") {
                return "\(SQLExporter.quoted(column.name)) * 1e0"
            }
            if type.range(of: #"^(enum|set)\((.*,)?''[,)]"#, options: .regularExpression) != nil {
                return "\(SQLExporter.quoted(column.name)) + 0"
            }
            return SQLExporter.quoted(column.name)
        }
        let selectList = selectExpressions.joined(separator: ", ")

        // In the key's own order, not the table's, so ORDER BY walks its
        // index instead of sorting the table.
        let keyColumnNames = try await introspection.primaryKeyColumnNames(forTable: table.name, inDatabase: database.name)
        // Resolved once: which positions in a fetched row carry the key
        // values that seed the next page's `WHERE`.
        let keyIndexes = keyColumnNames.compactMap { key in columns.firstIndex { $0.name == key } }
        // ENUM and SET sort by member number and BIT by value, but compare
        // differently with the 'text' or X'..' a seek would start from, so
        // a page would skip or repeat rows (or, for BIT, never end).
        let canSeekByKey = !keyColumnNames.isEmpty && keyIndexes.count == keyColumnNames.count
            && !keyIndexes.contains { ["enum", "set", "bit"].contains(where: columns[$0].mysqlType.lowercased().hasPrefix) }
        let quotedKeys = keyColumnNames.map(SQLExporter.quoted)
        // shortcut: a sort only looks at a value's first max_sort_length
        // bytes (1024), so key-less rows whose long TEXT or BLOB values share
        // those could still trade places on a server that doesn't keep ties in
        // row order (MariaDB 10.4 does); order by a hash of such columns too
        // if that turns up.
        let orderList = keyColumnNames.isEmpty
            ? selectExpressions.map { "CAST(\($0) AS BINARY)" }.joined(separator: ", ")
            : quotedKeys.joined(separator: ", ")

        var lastKeyLiterals: [String]?
        var offset = 0
        var rowsWritten = 0
        var wroteAnyRows = false

        while true {
            try Task.checkCancellation()

            var sql = "SELECT \(selectList) FROM \(qualifiedTable)"
            if canSeekByKey, let lastKeyLiterals {
                // (a, b) > (x, y) written out as (a > x) OR (a = x AND b > y):
                // MariaDB reads that as a range of the key's index, but the
                // row comparison by scanning the key from its start, which
                // makes every page cost as much as all the pages before it.
                let after = quotedKeys.indices.map { column in
                    (0..<column).map { "\(quotedKeys[$0]) = \(lastKeyLiterals[$0])" } + ["\(quotedKeys[column]) > \(lastKeyLiterals[column])"]
                }
                sql += " WHERE " + after.map { "(" + $0.joined(separator: " AND ") + ")" }.joined(separator: " OR ")
            }
            sql += " ORDER BY \(orderList) LIMIT \(dataPageSize)"
            if !canSeekByKey {
                sql += " OFFSET \(offset)"
            }

            let mysqlRows = try await service.textQuery(sql)
            guard !mysqlRows.isEmpty else { break }

            let rows: [[String]] = mysqlRows.map { row in
                zip(row.columnDefinitions, row.values).map { SQLExporter.sqlLiteral($1, column: $0) }
            }

            // Deferred until the first page actually arrives, so an empty
            // table doesn't get a stray LOCK/UNLOCK pair around nothing.
            if !wroteAnyRows {
                wroteAnyRows = true
                if options.file.lockInsertStatements {
                    try fileHandle.write(contentsOf: Data("LOCK TABLES \(SQLExporter.quoted(table.name)) WRITE;\n".utf8))
                }
            }

            let statements = SQLExporter.insertStatements(
                into: SQLExporter.quoted(table.name),
                columnNames: columns.map(\.name),
                literalRows: rows,
                maxRowsPerStatement: options.file.useExtendedInserts ? 500 : 1
            )
            // `write(contentsOf:)` throws when the disk is full, so the
            // backup stops with an error and its temporary file is removed;
            // `write(_:)` raises an Objective-C exception, which crashes.
            for statement in statements {
                try fileHandle.write(contentsOf: Data((statement + "\n").utf8))
            }

            rowsWritten += rows.count
            if canSeekByKey, let lastRow = rows.last {
                lastKeyLiterals = keyIndexes.map { lastRow[$0] }
            } else {
                offset += rows.count
            }

            // Advances the percentage *within* this table, which is the
            // whole point of row units — a single huge table used to leave
            // the bar frozen for its entire duration.
            progress = Progress(
                completedObjects: progress?.completedObjects ?? 0,
                totalObjects: progress?.totalObjects ?? 0,
                completedUnits: unitsBeforeCurrentObject + rowsWritten,
                totalUnits: totalUnits,
                currentObjectDescription: String(localized: "Table: \(table.name) (\(rowsWritten) rows)")
            )

            // A short page means the table ended — no need for one more
            // round trip just to see an empty result.
            if mysqlRows.count < dataPageSize { break }
        }

        guard wroteAnyRows else { return }
        if options.file.lockInsertStatements {
            try fileHandle.write(contentsOf: Data("UNLOCK TABLES;\n".utf8))
        }
        try fileHandle.write(contentsOf: Data("\n".utf8))
    }

    /// Before the first view, every selected view is created as a stand-in
    /// with the same column names, as mysqldump does, so a view built on one
    /// that comes after it anyway still restores: `viewsInDependencyOrder`
    /// can't put both of two views that name each other first, and finds a
    /// name only spelled the way the view's own is. Each real definition
    /// then replaces its stand-in.
    private func writeViewStandIns(to fileHandle: FileHandle) async throws {
        for view in selectedViews.sorted(by: { $0.name < $1.name }) {
            let columns = try await introspection.columns(forTable: view.name, inDatabase: database.name)
            let selectList = columns.map { "1 AS \(SQLExporter.quoted($0.name))" }.joined(separator: ", ")
            try fileHandle.write(contentsOf: Data("CREATE OR REPLACE VIEW \(SQLExporter.quoted(view.name)) AS SELECT \(selectList);\n".utf8))
        }
        try fileHandle.write(contentsOf: Data("\n".utf8))
    }

    private func dumpView(_ view: TableInfo, to fileHandle: FileHandle) async throws {
        guard options.mode != .dataOnly else { return }
        if options.file.includeDropStatements {
            try fileHandle.write(contentsOf: Data((SQLExporter.dropViewStatement(view: view.name) + "\n").utf8))
        }
        let definition = try await introspection.viewDefinition(view.name, inDatabase: database.name)
        let createSQL = SQLExporter.createViewStatement(rawShowCreateView: definition.statement)
        // Under the connection collation it was created under, as mysqldump
        // does: its string literals take it ('a' = 'A' is true or false by
        // it). Not the character set its text came in, since the file's is
        // UTF-8 whatever that was.
        let collation = SQLExporter.escapeStringLiteral(definition.collationConnection)
        try fileHandle.write(contentsOf: Data((
            "SET @saved_collation_connection = @@COLLATION_CONNECTION, COLLATION_CONNECTION = '\(collation)';\n"
                + createSQL + "\nSET COLLATION_CONNECTION = @saved_collation_connection;\n\n"
        ).utf8))
    }

    private func dumpRoutine(_ routine: RoutineInfo, to fileHandle: FileHandle) async throws {
        guard options.mode != .dataOnly else { return }
        if options.file.includeDropStatements {
            try fileHandle.write(contentsOf: Data((SQLExporter.dropRoutineStatement(routine) + "\n").utf8))
        }
        let definition = try await introspection.routineDefinition(routine)
        try fileHandle.write(contentsOf: Data((creationStatement(definition) + "\n\n").utf8))
    }

    private func dumpTrigger(_ trigger: TriggerInfo, to fileHandle: FileHandle) async throws {
        guard options.mode != .dataOnly else { return }
        if options.file.includeDropStatements {
            try fileHandle.write(contentsOf: Data((SQLExporter.dropTriggerStatement(trigger) + "\n").utf8))
        }
        let definition = try await introspection.triggerDefinition(trigger)
        try fileHandle.write(contentsOf: Data((creationStatement(definition) + "\n\n").utf8))
    }

    private func dumpEvent(_ event: EventInfo, to fileHandle: FileHandle) async throws {
        guard options.mode != .dataOnly else { return }
        if options.file.includeDropStatements {
            try fileHandle.write(contentsOf: Data((SQLExporter.dropEventStatement(event) + "\n").utf8))
        }
        let definition = try await introspection.eventDefinition(event)
        try fileHandle.write(contentsOf: Data((creationStatement(definition) + "\n\n").utf8))
    }

    /// A routine, trigger or event's CREATE under the settings it was
    /// created with (`SQLExporter.underCreationSettings`). One created while
    /// the database's default collation was another, which gave the
    /// parameters and variables it declares without a character set theirs,
    /// is also created under that default, as mysqldump does, and the
    /// database's own put back after: a database the file is restored into
    /// ends up with this one's.
    private func creationStatement(_ definition: (statement: String, settings: SchemaIntrospectionService.CreationSettings)) -> String {
        let statement = SQLExporter.underCreationSettings(
            SQLExporter.delimiterWrappedRoutineStatement(rawShowCreateRoutine: definition.statement),
            definition.settings
        )
        guard let collation = definition.settings.databaseCollation, !databaseCollation.isEmpty, collation != databaseCollation else {
            return statement
        }
        return "ALTER DATABASE COLLATE '\(SQLExporter.escapeStringLiteral(collation))';\n\(statement)\n"
            + "ALTER DATABASE COLLATE '\(SQLExporter.escapeStringLiteral(databaseCollation))';"
    }

    private func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "\(mysqlError)"
        }
        return error.localizedDescription
    }
}
