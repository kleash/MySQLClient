import Foundation

/// Schema + data: a `CREATE TABLE IF NOT EXISTS` (built from the server's
/// own `SHOW CREATE TABLE` output — see `SchemaIntrospectionService
/// .showCreateTable`, reusing its exact DDL rather than reconstructing one,
/// the same convention `showCreateView`/`showCreateRoutine` already use)
/// followed by one `INSERT INTO` statement per row.
enum SQLExporter {
    /// `` `name` ``, with any backtick inside doubled.
    static func quoted(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// Swaps the leading `CREATE TABLE` for `CREATE TABLE IF NOT EXISTS` and
    /// terminates the statement — `SHOW CREATE TABLE`'s own output has
    /// neither the `IF NOT EXISTS` clause nor a trailing `;`.
    static func createTableStatement(rawShowCreateTable: String) -> String {
        guard let range = rawShowCreateTable.range(of: "CREATE TABLE ") else {
            return rawShowCreateTable + ";"
        }
        var result = rawShowCreateTable
        result.replaceSubrange(range, with: "CREATE TABLE IF NOT EXISTS ")
        return result + ";"
    }

    /// A view's SQL export is just its (re-runnable) definition — unlike a
    /// table, a view has no data of its own to freeze as `INSERT`
    /// statements; re-running the view's own query is what reproduces its
    /// rows, and most views aren't even `INSERT`-able in the first place.
    ///
    /// `SHOW CREATE VIEW`'s raw output already starts with `CREATE
    /// [ALGORITHM=...] [DEFINER=...] [SQL SECURITY ...] VIEW ...` — `OR
    /// REPLACE` is spliced in right after the leading `CREATE ` so
    /// re-running the exported file redefines the view instead of failing
    /// on "view already exists".
    static func createViewStatement(rawShowCreateView: String) -> String {
        guard let range = rawShowCreateView.range(of: "CREATE ") else {
            return rawShowCreateView + ";"
        }
        var result = rawShowCreateView
        result.replaceSubrange(range, with: "CREATE OR REPLACE ")
        return result + ";"
    }

    /// One row, one statement — not a batched multi-row `VALUES (...),(...)`
    /// list. Simpler, keeps this function pure/single-purpose, and matches
    /// the HeidiSQL-style export this dialog is modeled on.
    static func insertStatement(
        database: String,
        table: String,
        columns: [ColumnInfo],
        values: [RowValue]
    ) -> String {
        let qualified = "\(quoted(database)).\(quoted(table))"
        let columnList = columns.map { quoted($0.name) }.joined(separator: ", ")
        let valueList = values.map(sqlLiteral).joined(separator: ", ")
        return "INSERT INTO \(qualified) (\(columnList)) VALUES (\(valueList));"
    }

    /// One value as a SQL literal. Also used outside INSERT building — the
    /// backup's keyset pagination embeds a page's last primary-key values
    /// into the next page's `WHERE` clause.
    static func sqlLiteral(_ value: RowValue) -> String {
        switch value {
        case .null: return "NULL"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return "'\(escapeStringLiteral(value))'"
        case .text(let value): return "'\(escapeStringLiteral(value))'"
        case .date(let value): return "'\(escapeStringLiteral(RowValue.dateFormatter.string(from: value)))'"
        case .blob(let value): return hexLiteral(value)
        }
    }

    /// Backslash first, then the quote — doubling the quote after
    /// backslash-escaping is safe (MySQL accepts both escaping styles for a
    /// literal quote simultaneously), whereas the reverse order would
    /// re-mangle the backslashes this same pass just inserted.
    static func escapeStringLiteral(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }

    /// MySQL's native binary literal syntax — used for `.blob` values
    /// rather than trying to force raw bytes through a quoted string.
    static func hexLiteral(_ data: Data) -> String {
        guard !data.isEmpty else { return "X''" }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return "X'\(hex)'"
    }

    static func write(
        database: String,
        table: String,
        createTableSQL: String,
        columns: [ColumnInfo],
        rows: [[RowValue]],
        to fileHandle: FileHandle
    ) throws {
        fileHandle.write(Data((createTableSQL + "\n\n").utf8))
        for row in rows {
            let statement = insertStatement(database: database, table: table, columns: columns, values: row)
            fileHandle.write(Data((statement + "\n").utf8))
        }
    }

    // MARK: - Database Backup

    static func dropTableStatement(database: String, table: String) -> String {
        "DROP TABLE IF EXISTS \(quoted(database)).\(quoted(table));"
    }

    static func dropViewStatement(database: String, view: String) -> String {
        "DROP VIEW IF EXISTS \(quoted(database)).\(quoted(view));"
    }

    /// Works for both procedures and functions via `RoutineInfo.kind
    /// .sqlKeyword` — same "one type instead of two" principle
    /// `RoutineKind`'s own doc comment describes.
    static func dropRoutineStatement(_ routine: RoutineInfo) -> String {
        "DROP \(routine.kind.sqlKeyword) IF EXISTS \(quoted(routine.database)).\(quoted(routine.name));"
    }

    /// Wraps a routine's raw `SHOW CREATE <kind>` output (from
    /// `SchemaIntrospectionService.showCreateRoutine`) in the same
    /// `DELIMITER $$ ... $$ DELIMITER ;` shape `SQLTemplate
    /// .createStoredProcedure`/`createFunction`'s skeletons already use —
    /// without it, a routine body's own internal `;`s would prematurely
    /// end the statement if the dump is ever replayed one-`;`-at-a-time
    /// (see `DelimiterScript.swift`'s doc comment for the same problem
    /// from the opposite direction).
    static func delimiterWrappedRoutineStatement(rawShowCreateRoutine: String) -> String {
        "DELIMITER $$\n\n\(rawShowCreateRoutine)$$\n\nDELIMITER ;"
    }

    /// mysqldump's `--extended-insert`: batches rows into as few multi-row
    /// `INSERT ... VALUES (...), (...), ...;` statements as possible,
    /// starting a new statement whenever the next row would exceed either
    /// cap. A single row that alone exceeds the byte budget is still
    /// emitted alone rather than looping forever trying to make it fit —
    /// forward progress is guaranteed either way.
    static func extendedInsertStatements(
        database: String,
        table: String,
        columns: [ColumnInfo],
        rows: [[RowValue]],
        maxRowsPerStatement: Int = 500,
        maxStatementByteBudget: Int = 512_000
    ) -> [String] {
        guard !rows.isEmpty else { return [] }
        let qualified = "\(quoted(database)).\(quoted(table))"
        let columnList = columns.map { quoted($0.name) }.joined(separator: ", ")
        let prefix = "INSERT INTO \(qualified) (\(columnList)) VALUES "

        var statements: [String] = []
        var currentTuples: [String] = []
        var currentByteCount = prefix.utf8.count

        func flush() {
            guard !currentTuples.isEmpty else { return }
            statements.append(prefix + currentTuples.joined(separator: ", ") + ";")
            currentTuples = []
            currentByteCount = prefix.utf8.count
        }

        for row in rows {
            let tuple = "(" + row.map(sqlLiteral).joined(separator: ", ") + ")"
            let tupleBytes = tuple.utf8.count + (currentTuples.isEmpty ? 0 : 2) // ", " separator
            let wouldExceedRowCap = currentTuples.count >= maxRowsPerStatement
            let wouldExceedByteCap = !currentTuples.isEmpty && currentByteCount + tupleBytes > maxStatementByteBudget
            if wouldExceedRowCap || wouldExceedByteCap {
                flush()
            }
            currentTuples.append(tuple)
            currentByteCount += tupleBytes
        }
        flush()
        return statements
    }
}
