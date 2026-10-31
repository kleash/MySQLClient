import Foundation
import MySQLNIO
import NIOCore

/// Schema + data: a `CREATE TABLE IF NOT EXISTS` (built from the server's
/// own `SHOW CREATE TABLE` output — see `SchemaIntrospectionService
/// .showCreateTable`, reusing its exact DDL rather than reconstructing one,
/// the same convention `showCreateView`/`showCreateRoutine` already use)
/// followed by one `INSERT INTO` statement per row.
enum SQLExporter {
    /// `` `name` ``, with any backtick inside doubled. Compared literally, as
    /// in `escapeStringLiteral`: a backtick followed by a combining mark is
    /// still a backtick.
    static func quoted(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``", options: .literal) + "`"
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
    ///
    /// NUL, line breaks and Ctrl-Z are written as `\0`, `\n`, `\r` and
    /// `\Z`, the way mysqldump writes them: the `mysql` client refuses a raw
    /// NUL in a script, and a value with its own line breaks would otherwise
    /// spread one statement over many lines of the file.
    ///
    /// Compared literally, character code by character code: by default a
    /// quote followed by a combining mark (U+0301) counts as one character
    /// that isn't a quote, and would end the literal early.
    static func escapeStringLiteral(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
            .replacingOccurrences(of: "'", with: "''", options: .literal)
            .replacingOccurrences(of: "\0", with: "\\0", options: .literal)
            .replacingOccurrences(of: "\n", with: "\\n", options: .literal)
            .replacingOccurrences(of: "\r", with: "\\r", options: .literal)
            .replacingOccurrences(of: "\u{1A}", with: "\\Z", options: .literal)
    }

    /// One value as the server sent it over the text protocol
    /// (`MySQLService.textQuery`), written so it reads back as exactly the
    /// same value: numbers as the server's own digits rather than through
    /// `Double`, dates and times as the server's own text (fractions of a
    /// second, TIME beyond a day or below zero, zero dates), binary
    /// strings, BIT and geometry as hex, and everything else quoted.
    static func sqlLiteral(_ value: ByteBuffer?, column: MySQLProtocol.ColumnDefinition41) -> String {
        guard let value else { return "NULL" }
        let bytes = Data(value.readableBytesView)
        switch column.columnType {
        case .tiny, .short, .long, .longlong, .int24, .year, .decimal, .newdecimal:
            return String(decoding: bytes, as: UTF8.self)
        case .float, .double:
            // The server prints negative zero as -0, which reads back as the
            // integer 0.
            let text = String(decoding: bytes, as: UTF8.self)
            return text == "-0" ? "-0e0" : text
        case .date, .newdate, .datetime, .timestamp, .time, .json:
            return "'\(escapeStringLiteral(String(decoding: bytes, as: UTF8.self)))'"
        default:
            // Numbers and dates report the binary character set as well,
            // which is why they're handled above and only this branch
            // goes by it.
            if column.characterSet == .binary {
                return hexLiteral(bytes)
            }
            return "'\(escapeStringLiteral(String(decoding: bytes, as: UTF8.self)))'"
        }
    }

    /// MySQL's native binary literal syntax — used for `.blob` values
    /// rather than trying to force raw bytes through a quoted string.
    ///
    /// Two digits looked up per byte: formatting each byte as a string took
    /// about a second per MB, on the main actor, for every binary value a
    /// backup writes.
    static func hexLiteral(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var literal = Array("X'".utf8)
        literal.reserveCapacity(data.count * 2 + 3)
        for byte in data {
            literal.append(digits[Int(byte >> 4)])
            literal.append(digits[Int(byte & 0x0F)])
        }
        literal.append(UInt8(ascii: "'"))
        return String(decoding: literal, as: UTF8.self)
    }

    static func write(
        database: String,
        table: String,
        createTableSQL: String,
        columns: [ColumnInfo],
        rows: [[RowValue]],
        to fileHandle: FileHandle
    ) throws {
        // `write(contentsOf:)`, which throws when the write fails (a full
        // disk); `write(_:)` raises an Objective-C exception instead.
        try fileHandle.write(contentsOf: Data((createTableSQL + "\n\n").utf8))
        for row in rows {
            let statement = insertStatement(database: database, table: table, columns: columns, values: row)
            try fileHandle.write(contentsOf: Data((statement + "\n").utf8))
        }
    }

    // MARK: - Database Backup
    //
    // A backup names its objects without their database, like its CREATE
    // statements, so the file restores into whichever database is current:
    // the one its own USE picks, or another one when that's left out.

    static func dropTableStatement(table: String) -> String {
        "DROP TABLE IF EXISTS \(quoted(table));"
    }

    static func dropViewStatement(view: String) -> String {
        "DROP VIEW IF EXISTS \(quoted(view));"
    }

    /// Works for both procedures and functions via `RoutineInfo.kind
    /// .sqlKeyword` — same "one type instead of two" principle
    /// `RoutineKind`'s own doc comment describes.
    static func dropRoutineStatement(_ routine: RoutineInfo) -> String {
        "DROP \(routine.kind.sqlKeyword) IF EXISTS \(quoted(routine.name));"
    }

    static func dropTriggerStatement(_ trigger: TriggerInfo) -> String {
        "DROP TRIGGER IF EXISTS \(quoted(trigger.name));"
    }

    static func dropEventStatement(_ event: EventInfo) -> String {
        "DROP EVENT IF EXISTS \(quoted(event.name));"
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

    /// `statement` run under the SQL mode and connection collation an object
    /// was created under, as mysqldump does, so the restored routine,
    /// trigger or event keeps them; the session's own are put back after.
    /// An event also gets the time zone its schedule was written in.
    static func underCreationSettings(_ statement: String, _ settings: SchemaIntrospectionService.CreationSettings) -> String {
        var set = "SET @saved_sql_mode = @@SQL_MODE, SQL_MODE = '\(escapeStringLiteral(settings.sqlMode))';\n"
            + "SET @saved_collation_connection = @@COLLATION_CONNECTION, COLLATION_CONNECTION = '\(escapeStringLiteral(settings.collationConnection))';\n"
        var reset = "SET SQL_MODE = @saved_sql_mode, COLLATION_CONNECTION = @saved_collation_connection;"
        if let timeZone = settings.timeZone {
            set += "SET @saved_time_zone = @@TIME_ZONE, TIME_ZONE = '\(escapeStringLiteral(timeZone))';\n"
            reset += "\nSET TIME_ZONE = @saved_time_zone;"
        }
        return set + statement + "\n" + reset
    }

    /// mysqldump's `--extended-insert`: batches rows into as few multi-row
    /// `INSERT ... VALUES (...), (...), ...;` statements as possible,
    /// starting a new statement whenever the next row would exceed either
    /// cap. A single row that alone exceeds the byte budget is still
    /// emitted alone rather than looping forever trying to make it fit —
    /// forward progress is guaranteed either way.
    ///
    /// Takes rows whose values are already SQL literals.
    /// `maxRowsPerStatement: 1` gives one INSERT per row.
    static func insertStatements(
        into qualifiedTable: String,
        columnNames: [String],
        literalRows: [[String]],
        maxRowsPerStatement: Int = 500,
        maxStatementByteBudget: Int = 512_000
    ) -> [String] {
        guard !literalRows.isEmpty else { return [] }
        let columnList = columnNames.map(quoted).joined(separator: ", ")
        let prefix = "INSERT INTO \(qualifiedTable) (\(columnList)) VALUES "

        var statements: [String] = []
        var currentTuples: [String] = []
        var currentByteCount = prefix.utf8.count

        func flush() {
            guard !currentTuples.isEmpty else { return }
            statements.append(prefix + currentTuples.joined(separator: ", ") + ";")
            currentTuples = []
            currentByteCount = prefix.utf8.count
        }

        for row in literalRows {
            let tuple = "(" + row.joined(separator: ", ") + ")"
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
