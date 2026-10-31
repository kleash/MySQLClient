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

    private let service: MySQLService
    private let introspection: SchemaIntrospectionService
    private var backupTask: Task<Void, Never>?
    /// Progress bookkeeping for the run in flight — see `Progress`.
    private var totalUnits = 0
    private var unitsBeforeCurrentObject = 0
    private var savedSessionSettings: (timeZone: String, sqlMode: String)?
    private var wroteViewStandIns = false

    init(service: MySQLService, database: DatabaseInfo) {
        self.service = service
        self.database = database
        self.introspection = SchemaIntrospectionService(service: service)
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
        await loadObjects()
    }

    /// Called when the VERİTABANI ADI picker changes. Re-suffixes the
    /// suggested filename the same way `TableExportViewModel` does for a
    /// format change — only when the current URL still looks
    /// auto-generated, so a path the user actually browsed to is left
    /// alone.
    func selectDatabase(_ newDatabase: DatabaseInfo) async {
        guard newDatabase != database else { return }
        let previousDefault = defaultOutputURL()
        database = newDatabase
        if outputFileURL == nil || outputFileURL == previousDefault {
            outputFileURL = defaultOutputURL()
        }
        await loadObjects()
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
    private func loadObjects() async {
        isLoadingObjects = true
        defer { isLoadingObjects = false }
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

        // Same reasoning, separately: listing events takes the EVENT
        // privilege, which a user who can read everything else may lack.
        do {
            allTriggers = try await introspection.listTriggers(inDatabase: database.name)
            allEvents = try await introspection.listEvents(inDatabase: database.name)
            selectedTriggers = Set(allTriggers)
            selectedEvents = Set(allEvents)
        } catch {
            allTriggers = []
            allEvents = []
            selectedTriggers = []
            selectedEvents = []
            let warning = String(localized: "Could not load the trigger/event list; the other objects were loaded: \(describe(error))")
            loadWarning = [loadWarning, warning].compactMap { $0 }.joined(separator: "\n")
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
    private func performBackup() async {
        defer { isRunning = false; backupTask = nil }

        guard let outputFileURL else { return }
        let objects = buildObjectPlan()
        let weights = await unitWeights(for: objects)
        totalUnits = weights.reduce(0, +)
        unitsBeforeCurrentObject = 0
        wroteViewStandIns = false
        progress = Progress(
            completedObjects: 0, totalObjects: objects.count,
            completedUnits: 0, totalUnits: totalUnits,
            currentObjectDescription: ""
        )

        do {
            try await AtomicFileWriter.write(to: outputFileURL) { fileHandle in
                try await self.beginSourceSession()
                do {
                    try await self.writeHeader(to: fileHandle)
                    for (index, object) in objects.enumerated() {
                        try Task.checkCancellation()
                        self.progress = Progress(
                            completedObjects: index, totalObjects: objects.count,
                            completedUnits: self.unitsBeforeCurrentObject, totalUnits: self.totalUnits,
                            currentObjectDescription: object.description
                        )
                        try await self.dump(object, to: fileHandle)
                        self.unitsBeforeCurrentObject += weights[index]
                        if self.interObjectDelay != .zero {
                            try await Task.sleep(for: self.interObjectDelay)
                        }
                    }
                    try Task.checkCancellation()
                    try await self.writeFooter(to: fileHandle)
                    try await self.endSourceSession()
                    self.progress = Progress(
                        completedObjects: objects.count, totalObjects: objects.count,
                        completedUnits: self.totalUnits, totalUnits: self.totalUnits,
                        currentObjectDescription: String(localized: "Completed")
                    )
                } catch {
                    // Best-effort: release whatever `beginSourceSession`
                    // took, even though the backup itself failed or was
                    // cancelled.
                    try? await self.endSourceSession()
                    throw error
                }
            }
            // Only reached once `AtomicFileWriter` has actually performed
            // its atomic replace — the file is genuinely on disk, not just
            // "the last statement inside the closure ran".
            didFinishSuccessfully = true
            AnalyticsService.trackFeatureUsed("db_backup")
        } catch is CancellationError {
            // User-initiated — not an error to surface.
        } catch {
            errorMessage = describe(error)
            AnalyticsService.trackError(error, feature: "db_backup")
        }
    }

    /// Tables first, with CREATE+DATA interleaved per table (not two
    /// passes — this is what makes "one table = one progress tick" work,
    /// and is safe because `FOREIGN_KEY_CHECKS=0` is on by default,
    /// matching real `mysqldump`'s own behavior). Views after all tables —
    /// `CREATE VIEW` genuinely requires its underlying tables to exist,
    /// unlike a constraint that's just disabled by a flag — and after a
    /// stand-in for each view (`writeViewStandIns`). Then routines,
    /// then triggers — after every table's rows, as mysqldump does, so
    /// restoring the rows doesn't fire them (an audit trigger would write
    /// its rows a second time) — in the order they fire, and events last.
    /// Alphabetical otherwise, since a `Set` has no defined order and dump
    /// output needs to be deterministic across runs.
    private func buildObjectPlan() -> [BackupObject] {
        selectedTables.sorted { $0.name < $1.name }.map { .table($0) }
            + selectedViews.sorted { $0.name < $1.name }.map { .view($0) }
            + selectedProcedures.sorted { $0.name < $1.name }.map { .procedure($0) }
            + selectedFunctions.sorted { $0.name < $1.name }.map { .function($0) }
            + allTriggers.filter(selectedTriggers.contains).map { .trigger($0) }
            + selectedEvents.sorted { $0.name < $1.name }.map { .event($0) }
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
    /// it's what buys a percentage that actually moves.
    private func unitWeights(for objects: [BackupObject]) async -> [Int] {
        var weights: [Int] = []
        weights.reserveCapacity(objects.count)
        for object in objects {
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

    /// `rawQuery`, not `execute` — matching `MainWindowView.dropRoutine`'s
    /// established precedent that `DROP PROCEDURE`/`FUNCTION` are rejected
    /// by MySQL's prepared-statement protocol; `LOCK TABLES`/`UNLOCK
    /// TABLES`/`START TRANSACTION`/`COMMIT` are the same family of
    /// session-control statement, so this uses the same safe default
    /// throughout rather than assuming `execute` handles them.
    ///
    /// Also reads in UTC and with an empty SQL mode, as mysqldump does:
    /// TIMESTAMP values come out in the session's time zone, and modes such
    /// as `ANSI_QUOTES` change how `SHOW CREATE` writes a statement. The
    /// file declares the same time zone (`writeHeader`). The connection is
    /// shared with the rest of the app, so `endSourceSession` puts the
    /// session's own settings back.
    private func beginSourceSession() async throws {
        let current = try await service.textQuery("SELECT @@SESSION.time_zone AS time_zone, @@SESSION.sql_mode AS sql_mode").first
        savedSessionSettings = (
            timeZone: current?.column("time_zone")?.string ?? "SYSTEM",
            sqlMode: current?.column("sql_mode")?.string ?? ""
        )
        _ = try await service.rawQuery("SET SESSION time_zone = '+00:00', sql_mode = ''")
        if options.source.lockTablesForReading, !selectedTables.isEmpty {
            let lockList = selectedTables.sorted { $0.name < $1.name }.map { "\(SQLExporter.quoted($0.name)) READ" }.joined(separator: ", ")
            _ = try await service.rawQuery("LOCK TABLES \(lockList)")
        }
        if options.source.useSingleTransaction {
            _ = try await service.rawQuery("START TRANSACTION WITH CONSISTENT SNAPSHOT")
        }
    }

    private func endSourceSession() async throws {
        if options.source.lockTablesForReading, !selectedTables.isEmpty {
            _ = try await service.rawQuery("UNLOCK TABLES")
        }
        if options.source.useSingleTransaction {
            _ = try await service.rawQuery("COMMIT")
        }
        if let saved = savedSessionSettings {
            savedSessionSettings = nil
            _ = try await service.rawQuery("""
                SET SESSION time_zone = '\(SQLExporter.escapeStringLiteral(saved.timeZone))', \
                sql_mode = '\(SQLExporter.escapeStringLiteral(saved.sqlMode))'
                """)
        }
    }

    // MARK: - Header / footer

    /// Starts with the session settings the file's contents depend on, as
    /// mysqldump does, because the server it's restored on may be set up
    /// differently: the character set the file is written in, the time zone
    /// its TIMESTAMP values are in, and an SQL mode that keeps an explicit 0
    /// in an AUTO_INCREMENT column (instead of taking the next number) and
    /// clears modes that would change how the file reads, such as
    /// `NO_BACKSLASH_ESCAPES`. `writeFooter` puts them back.
    private func writeHeader(to fileHandle: FileHandle) async throws {
        var header = """
            SET NAMES utf8mb4;
            SET @OLD_TIME_ZONE = @@TIME_ZONE, TIME_ZONE = '+00:00';
            SET @OLD_SQL_MODE = @@SQL_MODE, SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';

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
        fileHandle.write(Data(header.utf8))
    }

    private func writeFooter(to fileHandle: FileHandle) async throws {
        var footer = ""
        if options.file.setForeignKeyChecksToZero {
            footer += "SET FOREIGN_KEY_CHECKS=1;\n"
        }
        footer += "SET SQL_MODE = @OLD_SQL_MODE;\nSET TIME_ZONE = @OLD_TIME_ZONE;\n"
        fileHandle.write(Data(footer.utf8))
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
                fileHandle.write(Data((SQLExporter.dropTableStatement(database: database.name, table: table.name) + "\n").utf8))
            }
            let rawDDL = try await introspection.showCreateTable(table.name, inDatabase: database.name)
            let createSQL = SQLExporter.createTableStatement(rawShowCreateTable: rawDDL)
            fileHandle.write(Data((createSQL + "\n\n").utf8))
        }
        if options.mode != .structureOnly {
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
    /// would ask for the same page again forever.
    ///
    /// Ordering also makes paging *correct*, not just fast: `LIMIT` across
    /// separate queries has no row-order guarantee without an `ORDER BY`,
    /// so rows could otherwise repeat or vanish between pages. A table with
    /// no primary key is ordered by every column, so only rows that are identical
    /// (and so interchangeable) can trade places — the slow path, but such
    /// tables are rare and typically small.
    ///
    /// Columns are named rather than `SELECT *`, which leaves out
    /// invisible columns, and generated ones are skipped: the server
    /// computes them and refuses an INSERT that names them.
    private func dumpTableData(_ table: TableInfo, to fileHandle: FileHandle) async throws {
        let allColumns = try await introspection.columns(forTable: table.name, inDatabase: database.name)
        let columns = allColumns.filter { !$0.isGenerated }
        let qualifiedTable = try SchemaIntrospectionService.qualifiedIdentifier(database: database.name, name: table.name)
        // FLOAT is read as DOUBLE: the server prints a FLOAT with only six
        // significant digits (16777216 as 16777200), while the DOUBLE holds
        // its exact value, which converts back to the very same FLOAT.
        let selectList = columns.map { column in
            column.mysqlType.lowercased().hasPrefix("float")
                ? "\(SQLExporter.quoted(column.name)) + 0e0"
                : SQLExporter.quoted(column.name)
        }.joined(separator: ", ")

        let keyColumnNames = allColumns.filter(\.isPrimaryKey).map(\.name)
        // Resolved once: which positions in a fetched row carry the key
        // values that seed the next page's `WHERE`.
        let keyIndexes = keyColumnNames.compactMap { key in columns.firstIndex { $0.name == key } }
        let canSeekByKey = !keyColumnNames.isEmpty && keyIndexes.count == keyColumnNames.count
        let quotedKeyList = keyColumnNames.map(SQLExporter.quoted).joined(separator: ", ")
        let orderList = canSeekByKey ? quotedKeyList : selectList

        var lastKeyLiterals: [String]?
        var offset = 0
        var rowsWritten = 0
        var wroteAnyRows = false

        while true {
            try Task.checkCancellation()

            var sql = "SELECT \(selectList) FROM \(qualifiedTable)"
            if canSeekByKey, let lastKeyLiterals {
                // Row-constructor comparison, so a composite key pages
                // correctly as one ordered tuple rather than needing a
                // hand-expanded chain of ORs.
                sql += " WHERE (\(quotedKeyList)) > (\(lastKeyLiterals.joined(separator: ", ")))"
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
                    fileHandle.write(Data("LOCK TABLES \(SQLExporter.quoted(table.name)) WRITE;\n".utf8))
                }
            }

            let statements = SQLExporter.insertStatements(
                into: qualifiedTable,
                columnNames: columns.map(\.name),
                literalRows: rows,
                maxRowsPerStatement: options.file.useExtendedInserts ? 500 : 1
            )
            for statement in statements {
                fileHandle.write(Data((statement + "\n").utf8))
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
            fileHandle.write(Data("UNLOCK TABLES;\n".utf8))
        }
        fileHandle.write(Data("\n".utf8))
    }

    /// Before the first view, every selected view is created as a stand-in
    /// with the same column names, as mysqldump does: a view can be built
    /// on another view that sorts after it, which has to exist by the time
    /// it's created. Each real definition then replaces its stand-in.
    private func writeViewStandIns(to fileHandle: FileHandle) async throws {
        for view in selectedViews.sorted(by: { $0.name < $1.name }) {
            let columns = try await introspection.columns(forTable: view.name, inDatabase: database.name)
            let selectList = columns.map { "1 AS \(SQLExporter.quoted($0.name))" }.joined(separator: ", ")
            fileHandle.write(Data("CREATE OR REPLACE VIEW \(SQLExporter.quoted(view.name)) AS SELECT \(selectList);\n".utf8))
        }
        fileHandle.write(Data("\n".utf8))
    }

    private func dumpView(_ view: TableInfo, to fileHandle: FileHandle) async throws {
        guard options.mode != .dataOnly else { return }
        if options.file.includeDropStatements {
            fileHandle.write(Data((SQLExporter.dropViewStatement(database: database.name, view: view.name) + "\n").utf8))
        }
        let rawDDL = try await introspection.showCreateView(view.name, inDatabase: database.name)
        let createSQL = SQLExporter.createViewStatement(rawShowCreateView: rawDDL)
        fileHandle.write(Data((createSQL + "\n\n").utf8))
    }

    private func dumpRoutine(_ routine: RoutineInfo, to fileHandle: FileHandle) async throws {
        guard options.mode != .dataOnly else { return }
        if options.file.includeDropStatements {
            fileHandle.write(Data((SQLExporter.dropRoutineStatement(routine) + "\n").utf8))
        }
        let definition = try await introspection.routineDefinition(routine)
        let wrapped = SQLExporter.delimiterWrappedRoutineStatement(rawShowCreateRoutine: definition.statement)
        fileHandle.write(Data((SQLExporter.underCreationSettings(wrapped, definition.settings) + "\n\n").utf8))
    }

    private func dumpTrigger(_ trigger: TriggerInfo, to fileHandle: FileHandle) async throws {
        guard options.mode != .dataOnly else { return }
        if options.file.includeDropStatements {
            fileHandle.write(Data((SQLExporter.dropTriggerStatement(trigger) + "\n").utf8))
        }
        let definition = try await introspection.triggerDefinition(trigger)
        let wrapped = SQLExporter.delimiterWrappedRoutineStatement(rawShowCreateRoutine: definition.statement)
        fileHandle.write(Data((SQLExporter.underCreationSettings(wrapped, definition.settings) + "\n\n").utf8))
    }

    private func dumpEvent(_ event: EventInfo, to fileHandle: FileHandle) async throws {
        guard options.mode != .dataOnly else { return }
        if options.file.includeDropStatements {
            fileHandle.write(Data((SQLExporter.dropEventStatement(event) + "\n").utf8))
        }
        let definition = try await introspection.eventDefinition(event)
        let wrapped = SQLExporter.delimiterWrappedRoutineStatement(rawShowCreateRoutine: definition.statement)
        fileHandle.write(Data((SQLExporter.underCreationSettings(wrapped, definition.settings) + "\n\n").utf8))
    }

    private func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "\(mysqlError)"
        }
        return error.localizedDescription
    }
}
