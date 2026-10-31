import Foundation
import MySQLNIO

/// Reads database/table/column/key metadata via `SHOW` statements. MySQL has
/// no parameterized-identifier support, so identifiers are never bound as
/// `?` params — they're validated then backtick-escaped instead.
struct SchemaIntrospectionService {
    let service: MySQLService

    func listDatabases() async throws -> [DatabaseInfo] {
        let rows = try await service.query("SHOW DATABASES")
        return rows.compactMap { row in
            guard let columnName = row.columnDefinitions.first?.name,
                  let name = row.column(columnName)?.string else {
                return nil
            }
            return DatabaseInfo(name: name)
        }
    }

    /// `SHOW FULL TABLES` distinguishes base tables from views in one query
    /// instead of two — the first column's label varies (`Tables_in_<db>`),
    /// so it's read positionally like `SHOW TABLES`/`SHOW DATABASES`.
    func listTablesAndViews(inDatabase database: String) async throws -> [TableInfo] {
        let quotedDatabase = try Self.quotedIdentifier(database)
        let rows = try await service.query("SHOW FULL TABLES FROM \(quotedDatabase)")
        return rows.compactMap { row -> TableInfo? in
            guard let nameColumn = row.columnDefinitions.first?.name,
                  let name = row.column(nameColumn)?.string else {
                return nil
            }
            let type = row.column("Table_type")?.string
            return TableInfo(database: database, name: name, isView: type == "VIEW", isSequence: type == "SEQUENCE")
        }
    }

    /// `FULL` variant so column comments come along — the Alter Table form
    /// re-emits the whole definition on change, and without the original
    /// comment a `CHANGE COLUMN` would silently wipe it.
    func columns(forTable table: String, inDatabase database: String) async throws -> [ColumnInfo] {
        let qualifiedTable = try Self.qualifiedIdentifier(database: database, name: table)
        let primaryKeyColumns = Set(try await primaryKeyColumnNames(forTable: table, inDatabase: database))
        let rows = try await service.query("SHOW FULL COLUMNS FROM \(qualifiedTable)")
        return rows.compactMap { row -> ColumnInfo? in
            guard let name = row.column("Field")?.string else { return nil }
            let type = row.column("Type")?.string ?? ""
            let isNullable = (row.column("Null")?.string ?? "NO") == "YES"
            let extra = row.column("Extra")?.string ?? ""
            let comment = row.column("Comment")?.string
            return ColumnInfo(
                name: name,
                mysqlType: type,
                isNullable: isNullable,
                isPrimaryKey: primaryKeyColumns.contains(name),
                isAutoIncrement: extra.localizedCaseInsensitiveContains("auto_increment"),
                defaultValue: row.column("Default")?.string,
                comment: (comment?.isEmpty ?? true) ? nil : comment,
                // "VIRTUAL GENERATED"/"STORED GENERATED", or MariaDB's
                // "PERSISTENT"; not MySQL's "DEFAULT_GENERATED", which only
                // marks an expression default.
                isGenerated: extra.contains("VIRTUAL") || extra.contains("STORED GENERATED") || extra.contains("PERSISTENT")
            )
        }
    }

    /// Composite-key aware: returns every column that's part of the PRIMARY KEY.
    func primaryKeyColumnNames(forTable table: String, inDatabase database: String) async throws -> [String] {
        let qualifiedTable = try Self.qualifiedIdentifier(database: database, name: table)
        let rows = try await service.query("SHOW KEYS FROM \(qualifiedTable) WHERE Key_name = 'PRIMARY'")
        return rows.compactMap { $0.column("Column_name")?.string }
    }

    /// Groups `SHOW INDEX` rows (one row per indexed column) into one
    /// `IndexInfo` per `Key_name`, columns ordered by `Seq_in_index`.
    func indexes(forTable table: String, inDatabase database: String) async throws -> [IndexInfo] {
        let qualifiedTable = try Self.qualifiedIdentifier(database: database, name: table)
        let rows = try await service.query("SHOW INDEX FROM \(qualifiedTable)")

        var order: [String] = []
        var columnsByKey: [String: [(seq: Int, column: String)]] = [:]
        var metaByKey: [String: (isUnique: Bool, indexType: String)] = [:]

        for row in rows {
            guard let keyName = row.column("Key_name")?.string,
                  let columnName = row.column("Column_name")?.string else { continue }
            if columnsByKey[keyName] == nil {
                order.append(keyName)
                columnsByKey[keyName] = []
                let nonUnique = row.column("Non_unique")?.int ?? 1
                metaByKey[keyName] = (isUnique: nonUnique == 0, indexType: row.column("Index_type")?.string ?? "")
            }
            let seq = row.column("Seq_in_index")?.int ?? 0
            columnsByKey[keyName]?.append((seq, columnName))
        }

        return order.compactMap { keyName in
            guard let meta = metaByKey[keyName], let cols = columnsByKey[keyName] else { return nil }
            let orderedColumns = cols.sorted { $0.seq < $1.seq }.map(\.column)
            return IndexInfo(name: keyName, columns: orderedColumns, isUnique: meta.isUnique, indexType: meta.indexType)
        }
    }

    /// The view's `CREATE VIEW` statement, exactly as MySQL would print it
    /// after a plain `SHOW CREATE VIEW view_name` (no schema qualifiers on
    /// the view/table/column references) — needed even though the query
    /// itself must use the qualified form (the connection isn't necessarily
    /// sitting in `database`'s context). MySQL always fully qualifies every
    /// reference with the queried name when the view identifier itself was
    /// qualified, so the leading `` `database`. `` is stripped back out
    /// afterward (`unqualified`) to match what a `USE database; SHOW CREATE
    /// VIEW` would have produced.
    func showCreateView(_ view: String, inDatabase database: String) async throws -> String {
        try await viewDefinition(view, inDatabase: database).statement
    }

    /// `showCreateView`, with the connection collation the view was created
    /// under, which its string literals take.
    func viewDefinition(_ view: String, inDatabase database: String) async throws -> (statement: String, collationConnection: String) {
        let qualifiedView = try Self.qualifiedIdentifier(database: database, name: view)
        let rows = try await service.query("SHOW CREATE VIEW \(qualifiedView)")
        guard let row = rows.first, let raw = row.column("Create View")?.string else {
            throw MySQLServiceError.invalidIdentifier(view)
        }
        return (Self.unqualified(raw, database: database), row.column("collation_connection")?.string ?? "")
    }

    /// The table's `CREATE TABLE` statement, exactly as MySQL would print it
    /// from `SHOW CREATE TABLE table_name` — the schema half of the SQL
    /// export format (`SQLExporter`). It names its own database only where a
    /// DEFAULT takes numbers from a MariaDB sequence, whichever database is
    /// current (`` nextval(`db`.`seq`) ``), and that comes out the same way
    /// as in `showCreateView`.
    func showCreateTable(_ table: String, inDatabase database: String) async throws -> String {
        let qualifiedTable = try Self.qualifiedIdentifier(database: database, name: table)
        let rows = try await service.query("SHOW CREATE TABLE \(qualifiedTable)")
        guard let raw = rows.first?.column("Create Table")?.string else {
            throw MySQLServiceError.invalidIdentifier(table)
        }
        return Self.unqualified(raw, database: database)
    }

    /// `statement` without `` `database`. `` in front of the names it
    /// qualifies. Strings and quoted names are matched whole, so the same
    /// text inside a string (`'see `shop`.t'`, a comment or a default) or
    /// further along another name (`` `other`.`shop`.`t` ``) stays as it is.
    static func unqualified(_ statement: String, database: String) -> String {
        let qualifier = SQLExporter.quoted(database) + "."
        // A string in single or double quotes, or a quoted name with the
        // names that follow it after dots.
        let token = #/'(?:[^'\\]|\\.|'')*'|"(?:[^"\\]|\\.|"")*"|`(?:[^`]|``)*`(?:\.`(?:[^`]|``)*`)*/#
        return statement.replacing(token) { match in
            match.output.hasPrefix(qualifier) ? match.output.dropFirst(qualifier.count) : match.output
        }
    }

    /// `SHOW CREATE DATABASE`: the database with its default character set
    /// and collation, which every table, routine and column created in it
    /// later inherits.
    func showCreateDatabase(_ database: String) async throws -> String {
        let rows = try await service.query("SHOW CREATE DATABASE \(try Self.quotedIdentifier(database))")
        guard let raw = rows.first?.column("Create Database")?.string else {
            throw MySQLServiceError.invalidIdentifier(database)
        }
        return raw
    }

    /// `SHOW <kind> STATUS` is server-wide by default; scoped here with a
    /// `WHERE Db = '...'` literal (same pattern as `collations(forCharset:)`
    /// — `SHOW` statements' patchy prepared-statement support is why this is
    /// a manually-escaped literal, not a bound `?` param) since `database`
    /// only ever comes from `SHOW DATABASES`, never raw user input.
    func listRoutines(_ kind: RoutineKind, inDatabase database: String) async throws -> [RoutineInfo] {
        let escaped = database.replacingOccurrences(of: "'", with: "''")
        let rows = try await service.query("SHOW \(kind.sqlKeyword) STATUS WHERE Db = '\(escaped)'")
        return rows.compactMap { row -> RoutineInfo? in
            guard let name = row.column("Name")?.string else { return nil }
            return RoutineInfo(database: database, name: name, kind: kind)
        }
    }

    /// The routine's `CREATE PROCEDURE`/`CREATE FUNCTION` statement, exactly
    /// as MySQL stored it. Unlike `showCreateView`, there's no
    /// schema-qualifier stripping needed — `SHOW CREATE <kind>` never
    /// qualifies the routine name or its body regardless of whether the
    /// query itself used a qualified or unqualified name (verified against a
    /// real server; a routine's body is stored close to verbatim, not
    /// recompiled with fully-qualified references the way a view's `SELECT`
    /// is).
    func showCreateRoutine(_ routine: RoutineInfo) async throws -> String {
        try await routineDefinition(routine).statement
    }

    /// What the server keeps with a routine, trigger or event besides its
    /// text: the SQL mode and connection collation it was created under,
    /// which apply every time it runs (`ANSI_QUOTES` changes how its body
    /// parses, the collation how its string literals compare).
    struct CreationSettings: Equatable {
        let sqlMode: String
        let collationConnection: String
        /// Events only: the time zone their schedule is in.
        var timeZone: String? = nil
        /// The database's default collation when it was created, which its
        /// parameters and variables declared without a character set take.
        var databaseCollation: String? = nil
    }

    /// `showCreateRoutine`, with the settings the routine was created under.
    func routineDefinition(_ routine: RoutineInfo) async throws -> (statement: String, settings: CreationSettings) {
        let qualified = try Self.qualifiedIdentifier(database: routine.database, name: routine.name)
        let rows = try await service.query("SHOW CREATE \(routine.kind.sqlKeyword) \(qualified)")
        guard let row = rows.first, let raw = row.column(routine.kind.createStatementColumn)?.string else {
            throw MySQLServiceError.invalidIdentifier(routine.name)
        }
        return (raw, Self.creationSettings(of: row))
    }

    /// The `sql_mode`, `collation_connection` and `Database Collation`
    /// columns every `SHOW CREATE PROCEDURE/FUNCTION/EVENT` and `SHOW
    /// TRIGGERS` row carries, and an event's `time_zone`.
    static func creationSettings(of row: MySQLRow) -> CreationSettings {
        CreationSettings(
            sqlMode: row.column("sql_mode")?.string ?? "",
            collationConnection: row.column("collation_connection")?.string ?? "",
            timeZone: row.column("time_zone")?.string,
            databaseCollation: row.column("Database Collation")?.string
        )
    }

    /// `SHOW TRIGGERS FROM db` — an identifier `FROM`, not a `WHERE Db =
    /// '...'` literal like `listRoutines`; that's the syntax MySQL defines
    /// for this statement, there's no alternate form to pick between.
    func listTriggers(inDatabase database: String) async throws -> [TriggerInfo] {
        let quotedDatabase = try Self.quotedIdentifier(database)
        let rows = try await service.query("SHOW TRIGGERS FROM \(quotedDatabase)")
        return rows.compactMap { row -> TriggerInfo? in
            guard let name = row.column("Trigger")?.string else { return nil }
            return TriggerInfo(
                database: database,
                name: name,
                table: row.column("Table")?.string ?? "",
                timing: row.column("Timing")?.string ?? "",
                event: row.column("Event")?.string ?? ""
            )
        }
    }

    /// `SHOW CREATE TRIGGER` returns the definition in `SQL Original
    /// Statement` — a different column name than `showCreateRoutine`'s.
    func showCreateTrigger(_ trigger: TriggerInfo) async throws -> String {
        let qualified = try Self.qualifiedIdentifier(database: trigger.database, name: trigger.name)
        let rows = try await service.query("SHOW CREATE TRIGGER \(qualified)")
        guard let raw = rows.first?.column("SQL Original Statement")?.string else {
            throw MySQLServiceError.invalidIdentifier(trigger.name)
        }
        return raw
    }

    /// The trigger's CREATE statement built from its `SHOW TRIGGERS` row,
    /// with the settings it was created under. Not `showCreateTrigger`'s:
    /// MariaDB keeps that as it was typed, so a trigger created as
    /// `` `db`.`name` `` ON `` `db`.`table` `` names its database, and
    /// restored into another one would go back into the original. Nor the
    /// FOLLOWS or PRECEDES it may have been created with: a trigger fires
    /// after the ones of its table, timing and event created before it, so
    /// creating them in the order SHOW TRIGGERS lists them keeps the order.
    func triggerDefinition(_ trigger: TriggerInfo) async throws -> (statement: String, settings: CreationSettings) {
        let rows = try await service.query("""
            SHOW TRIGGERS FROM \(try Self.quotedIdentifier(trigger.database)) \
            WHERE `Trigger` = '\(SQLExporter.escapeStringLiteral(trigger.name))'
            """)
        // Exactly this name: that comparison ignores case.
        guard let row = rows.first(where: { $0.column("Trigger")?.string == trigger.name }),
              let timing = row.column("Timing")?.string, let event = row.column("Event")?.string,
              let table = row.column("Table")?.string, let body = row.column("Statement")?.string,
              let definer = row.column("Definer")?.string else {
            throw MySQLServiceError.invalidIdentifier(trigger.name)
        }
        // `user@host`, unquoted: a host can't hold an @, a user name can. A
        // MariaDB role has no host.
        let quotedDefiner = definer.lastIndex(of: "@").map {
            SQLExporter.quoted(String(definer[..<$0])) + "@" + SQLExporter.quoted(String(definer[definer.index(after: $0)...]))
        } ?? SQLExporter.quoted(definer)
        let statement = "CREATE DEFINER=\(quotedDefiner) TRIGGER \(SQLExporter.quoted(trigger.name)) \(timing) \(event) "
            + "ON \(SQLExporter.quoted(table)) FOR EACH ROW \(body)"
        return (statement, Self.creationSettings(of: row))
    }

    /// `SHOW EVENTS FROM db` — same identifier-`FROM` shape as
    /// `listTriggers`.
    func listEvents(inDatabase database: String) async throws -> [EventInfo] {
        let quotedDatabase = try Self.quotedIdentifier(database)
        let rows = try await service.query("SHOW EVENTS FROM \(quotedDatabase)")
        return rows.compactMap { row -> EventInfo? in
            guard let name = row.column("Name")?.string else { return nil }
            return EventInfo(database: database, name: name, status: row.column("Status")?.string ?? "")
        }
    }

    /// `SHOW CREATE EVENT` returns the definition in `Create Event`.
    func showCreateEvent(_ event: EventInfo) async throws -> String {
        try await eventDefinition(event).statement
    }

    /// `showCreateEvent`, with the settings the event was created under.
    func eventDefinition(_ event: EventInfo) async throws -> (statement: String, settings: CreationSettings) {
        let qualified = try Self.qualifiedIdentifier(database: event.database, name: event.name)
        let rows = try await service.query("SHOW CREATE EVENT \(qualified)")
        guard let row = rows.first, let raw = row.column("Create Event")?.string else {
            throw MySQLServiceError.invalidIdentifier(event.name)
        }
        return (raw, Self.creationSettings(of: row))
    }

    /// Every character set the server supports, for the "Yeni Tablo" form's
    /// picker — the handful of hardcoded names a static list would have
    /// covered is nowhere near what real servers offer.
    func characterSets() async throws -> [String] {
        let rows = try await service.query("SHOW CHARACTER SET")
        return rows.compactMap { $0.column("Charset")?.string }.sorted()
    }

    /// Collations for one charset (or every collation on the server when
    /// `charset` is nil). `charset` is only ever a value this same method's
    /// sibling (`characterSets()`) returned — server-echoed, not raw user
    /// input — so it's safely embedded as a literal rather than bound,
    /// sidestepping `SHOW` statements' patchy prepared-statement support.
    func collations(forCharset charset: String? = nil) async throws -> [String] {
        var sql = "SHOW COLLATION"
        if let charset {
            sql += " WHERE Charset = '\(charset.replacingOccurrences(of: "'", with: "''"))'"
        }
        let rows = try await service.query(sql)
        return rows.compactMap { $0.column("Collation")?.string }.sorted()
    }

    /// Backtick-quotes a single identifier, doubling any backtick inside it
    /// the way the server itself does (`` `odd``name` `` is the table
    /// odd`name), so every name the server can hold can be addressed.
    static func quotedIdentifier(_ raw: String) throws -> String {
        guard !raw.isEmpty else {
            throw MySQLServiceError.invalidIdentifier(raw)
        }
        return SQLExporter.quoted(raw)
    }

    /// `` `database`.`table` `` — both parts individually validated/escaped.
    static func qualifiedIdentifier(database: String, name: String) throws -> String {
        "\(try quotedIdentifier(database)).\(try quotedIdentifier(name))"
    }
}
