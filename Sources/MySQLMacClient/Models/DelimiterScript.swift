import Foundation

/// Splits a `DELIMITER $$ ... $$ DELIMITER ;`-style script (the shape the
/// sidebar's "Oluştur ▸ Stored Procedure/Function/Trigger/Event" templates
/// and the "Alter View" action both produce) into the individual statements
/// the query console needs to run.
///
/// `DELIMITER` is a `mysql`-CLI-only directive, not real SQL — MySQL's wire
/// protocol has no such statement, so sending the literal text straight to
/// the server (as every other query the console runs does) fails with a
/// syntax error at `DELIMITER`. This mirrors what the real `mysql` CLI does
/// with the same script: track a current statement terminator (starting at
/// `;`), swap it whenever a `DELIMITER <token>` line is seen, and cut a new
/// statement out every time that terminator is hit outside a quoted string
/// or a comment.
enum DelimiterScript {
    /// `nil` when `script` has no `DELIMITER` line at all — the caller
    /// should fall back to sending it unmodified, exactly as before this
    /// existed, since every other kind of query the console runs (a plain
    /// `SELECT`, a hand-typed multi-line `INSERT`, …) must keep behaving
    /// identically. "Çalıştır" uses this: a `CREATE PROCEDURE`/`FUNCTION`/
    /// `TRIGGER` body with its own internal `;`s is only safe to send
    /// whole (today's behavior) when nothing here decides to split it —
    /// see `allStatements(from:)` for the always-split version "Tümünü
    /// Çalıştır" uses instead, and why *that* one carries a real caveat
    /// for exactly this case.
    static func statements(from script: String) -> [String]? {
        guard containsDelimiterDirective(script) else { return nil }
        return allStatements(from: script)
    }

    /// Whether `script` has a `DELIMITER <token>` line at all — the test
    /// `statements(from:)` opts in on.
    static func containsDelimiterDirective(_ script: String) -> Bool {
        // `[ \t]`, not `\s` — this must only match a directive that's
        // complete on one line, matching `commandLine`'s per-line
        // check below (`\s` would let the token match across a newline,
        // e.g. treating a stray "DELIMITER" line as directive by borrowing
        // the next line's first word as its token).
        script.range(of: #"(?im)^[ \t]*DELIMITER[ \t]+\S+[ \t]*$"#, options: .regularExpression) != nil
    }

    /// One statement cut out of a script, and where it came from.
    struct Statement: Equatable {
        let sql: String
        /// How many lines of the script precede the line this statement
        /// starts on. The server numbers the lines of an error from the
        /// start of whatever text it was sent, so this is what turns its
        /// "at line 3" back into a line of the script.
        let lineOffset: Int
    }

    /// Always splits — with a `DELIMITER` directive honored wherever one
    /// appears, defaulting to `;` everywhere else. Unlike `statements(from:)`,
    /// this never opts out just because the script has no `DELIMITER` line,
    /// which is exactly what "Tümünü Çalıştır" needs for a plain script like
    /// `USE db;\ncall proc();` — two independent statements with no
    /// `DELIMITER` in sight.
    ///
    /// The script is read the way the server's own lexer would read it: a
    /// terminator only counts outside `'…'`/`"…"`/`` `…` `` and outside
    /// `-- …`, `# …` and `/* … */` comments, and it counts wherever on the
    /// line it falls. The version before this cut only where a *line ended*
    /// with the terminator, so `SET NAMES utf8mb4; -- why` never ended its
    /// statement — the next one was glued on and the server rejected the
    /// pair as a syntax error — while a string or comment line that
    /// happened to end in `;` was cut in half.
    ///
    /// Each statement starts at its first piece of actual SQL: comments
    /// ahead of it are dropped, and a stretch that is nothing but comments
    /// (a script's closing remarks) produces no statement at all — sent on
    /// its own the server answers that with "Query was empty".
    ///
    /// The tradeoff: this has no `BEGIN…END` awareness (same as the real
    /// `mysql` CLI without `DELIMITER`), so a pasted `CREATE PROCEDURE`/
    /// `FUNCTION`/`TRIGGER` body that relies on being sent as one statement
    /// gets cut apart at its own internal `;`s instead of erroring clearly.
    /// That's why this isn't what the plain "Çalıştır" button uses.
    static func allStatements(from script: String) -> [String] {
        locatedStatements(from: script).map(\.sql)
    }

    /// `allStatements(from:)`, with each statement's position in the script.
    static func locatedStatements(from script: String) -> [Statement] {
        // Bytes, not `Character`s: everything the scan looks for is ASCII,
        // which never occurs inside a multi-byte UTF-8 sequence, so byte
        // offsets found here are always safe places to cut. It also keeps
        // a many-megabyte dump fast, and sees `\r\n` as two bytes where
        // `Character` sees one that isn't equal to "\n".
        let bytes = Array(script.utf8)
        return scan(bytes, isFinal: true).statements.compactMap { found in
            let statement = String(decoding: bytes[found.range], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return statement.isEmpty ? nil : Statement(sql: statement, lineOffset: found.line)
        }
    }

    /// What a scan that stopped part-way needs to carry on from there.
    struct ScanState: Equatable {
        var delimiter = Array(";".utf8)
        var isAtLineStart = true
        /// Line breaks before this point.
        var line = 0
        /// The server's sql_mode has NO_BACKSLASH_ESCAPES: a backslash in a
        /// string is then an ordinary character, so `'C:\'` is a whole
        /// string. The mysql client follows the server's status flag for
        /// this; only the caller, which talks to the server, can keep it
        /// up to date.
        var noBackslashEscapes = false
    }

    /// The scanner behind `locatedStatements(from:)`, over raw bytes, and
    /// able to work through a script a piece at a time (a dump too big to
    /// hold in memory, see `DatabaseRestoreViewModel`).
    ///
    /// With `isFinal` false, `bytes` may stop anywhere — inside a string, a
    /// comment or a `DELIMITER` line. The scan then returns only statements
    /// that are complete, `consumed` (how many leading bytes they took) and
    /// the state after them; the caller passes the rest again, with more
    /// bytes after it, and that state. Everything is decided exactly as one
    /// scan of the whole script would decide it, since a statement only
    /// ever ends at a delimiter or a whole `DELIMITER` line.
    ///
    /// Each statement comes back as its byte range in `bytes`, untrimmed,
    /// with the line it starts on; decoding is left to the caller.
    ///
    /// With `stopsAfterSQLMode`, the scan also stops right after a statement
    /// that mentions sql_mode, as if the bytes ended there: running it may
    /// change `noBackslashEscapes` for the rest.
    static func scan(
        _ bytes: [UInt8],
        from state: ScanState = ScanState(),
        isFinal: Bool,
        stopsAfterSQLMode: Bool = false
    ) -> (statements: [(range: Range<Int>, line: Int)], consumed: Int, state: ScanState) {
        let count = bytes.count
        var statements: [(range: Range<Int>, line: Int)] = []
        var delimiter = state.delimiter
        // Offset of the current statement's first byte of SQL (and the
        // line that byte is on), `nil` while only whitespace and comments
        // have been seen since the last one.
        var statementStart: (offset: Int, line: Int)?
        // Line breaks passed so far — every loop below that steps over a
        // "\n" has to count it.
        var line = state.line
        var isAtLineStart = state.isAtLineStart
        var index = 0
        // The last point where a statement had just ended: where a scan
        // that stops early can be picked up again.
        var boundary = (offset: 0, state: state)
        var stopped = false

        func endStatement(at end: Int) {
            guard let start = statementStart else { return }
            statementStart = nil
            statements.append((start.offset..<end, start.line))
            stopped = stopsAfterSQLMode && mentionsSQLMode(bytes[start.offset..<end])
        }

        // The state to carry on from here, between statements.
        func stateHere(isAtLineStart: Bool = false) -> ScanState {
            ScanState(delimiter: delimiter, isAtLineStart: isAtLineStart, line: line, noBackslashEscapes: state.noBackslashEscapes)
        }

        func byte(at offset: Int) -> UInt8? {
            offset < count ? bytes[offset] : nil
        }

        scanning: while index < count {
            if isAtLineStart {
                isAtLineStart = false
                if let directive = commandLine("delimiter", in: bytes, lineStart: index) {
                    // Without its line break, the line may go on in bytes
                    // not read yet (`DELIMITER $` of `DELIMITER $$`).
                    if !isFinal, directive.lineEnd == count { break scanning }
                    endStatement(at: index)
                    delimiter = directive.argument
                    index = directive.lineEnd
                    boundary = (index, stateHere())
                    if stopped { break scanning }
                    continue
                }
                // The MariaDB client (and the mysql client with --commands)
                // runs a `use` line that has no delimiter on its own, when
                // no statement has started yet.
                if statementStart == nil, let use = commandLine("use", in: bytes, lineStart: index),
                   !bytes[index..<use.lineEnd].contains(delimiter) {
                    if !isFinal, use.lineEnd == count { break scanning }
                    statementStart = (index, line)
                    endStatement(at: use.lineEnd)
                    index = use.lineEnd
                    boundary = (index, stateHere())
                    if stopped { break scanning }
                    continue
                }
            }

            let current = bytes[index]
            if current == delimiter[0], bytes[index...].starts(with: delimiter) {
                endStatement(at: index)
                index += delimiter.count
                boundary = (index, stateHere())
                if stopped { break scanning }
                continue
            }

            switch current {
            case UInt8(ascii: "\n"):
                isAtLineStart = true
                line += 1
                index += 1

            case UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: "`"):
                if statementStart == nil { statementStart = (index, line) }
                // A doubled quote (`'it''s'`) needs no special case: it
                // reads as one string closing and the next one opening.
                // Backslash escapes exist in strings, not in identifiers.
                let quote = current
                index += 1
                while index < count, bytes[index] != quote {
                    let isEscape = bytes[index] == UInt8(ascii: "\\") && quote != UInt8(ascii: "`") && !state.noBackslashEscapes
                    for skipped in index..<min(index + (isEscape ? 2 : 1), count) where bytes[skipped] == UInt8(ascii: "\n") {
                        line += 1
                    }
                    index += isEscape ? 2 : 1
                }
                index = min(index + 1, count)

            // `--` only opens a comment when whitespace (or the end of the
            // script) follows — `5--3` is arithmetic, as it is to MySQL.
            case UInt8(ascii: "-") where byte(at: index + 1) == UInt8(ascii: "-") && (byte(at: index + 2) ?? 0) <= UInt8(ascii: " "),
                 UInt8(ascii: "#"):
                while index < count, bytes[index] != UInt8(ascii: "\n") {
                    index += 1
                }

            case UInt8(ascii: "/") where byte(at: index + 1) == UInt8(ascii: "*"):
                // `/*!40101 … */` (and MariaDB's `/*M! … */`) is SQL the
                // server executes, so unlike a real comment it makes a
                // statement on its own — mysqldump's preamble is built
                // from exactly these. Its inside is read on as SQL, as the
                // mysql client reads it: a `*/` in a string there doesn't
                // end it, and a delimiter ends the statement.
                let isExecutable = byte(at: index + 2) == UInt8(ascii: "!")
                    || (byte(at: index + 2) == UInt8(ascii: "M") && byte(at: index + 3) == UInt8(ascii: "!"))
                if isExecutable {
                    if statementStart == nil { statementStart = (index, line) }
                    index += 2
                    break
                }
                index += 2
                while index < count, !(bytes[index] == UInt8(ascii: "*") && byte(at: index + 1) == UInt8(ascii: "/")) {
                    if bytes[index] == UInt8(ascii: "\n") { line += 1 }
                    index += 1
                }
                index = min(index + 2, count)

            default:
                if statementStart == nil, current > UInt8(ascii: " ") { statementStart = (index, line) }
                index += 1
            }
        }

        guard isFinal, !stopped else {
            return (statements, boundary.offset, boundary.state)
        }
        endStatement(at: count)
        return (statements, count, stateHere(isAtLineStart: isAtLineStart))
    }

    /// Whether a statement mentions sql_mode, so may change how the server
    /// reads a backslash in the strings after it (`noBackslashEscapes`).
    static func mentionsSQLMode(_ statement: ArraySlice<UInt8>) -> Bool {
        let name = Array("sql_mode".utf8)
        // `| 0x20` lowercases an ASCII letter; `_` changes alike on both sides.
        return statement.indices.dropLast(name.count - 1).contains { start in
            statement[start] | 0x20 == name[0] && zip(statement[start...], name).allSatisfy { $0 | 0x20 == $1 | 0x20 }
        }
    }

    /// Splits a script handed over a piece at a time — a file read in
    /// chunks — into the same statements `locatedStatements(from:)` finds
    /// in the whole of it. Statements come back as raw bytes: one is only
    /// ever cut at a delimiter, never inside a multi-byte character, and
    /// the caller decides how strictly to decode it.
    ///
    /// A statement longer than the chunks it arrives in is scanned again
    /// from its start with each chunk, so a caller reading a file should
    /// grow its reads while no statement ends (`DatabaseRestoreViewModel`
    /// doubles them).
    ///
    /// It hands over nothing past a statement that mentions sql_mode: the
    /// caller runs it, sets `noBackslashEscapes` from the server, and asks
    /// for the rest with `feed` of no bytes (or `finish`).
    struct Splitter {
        private var pending: [UInt8] = []
        private var state = ScanState()

        var noBackslashEscapes: Bool {
            get { state.noBackslashEscapes }
            set { state.noBackslashEscapes = newValue }
        }

        /// The statements `bytes` completes.
        mutating func feed(_ bytes: some Sequence<UInt8>) -> [(sql: [UInt8], line: Int)] {
            pending.append(contentsOf: bytes)
            return take(isFinal: false)
        }

        /// Whatever is left once the script has ended, as the last statement.
        mutating func finish() -> [(sql: [UInt8], line: Int)] {
            take(isFinal: true)
        }

        private mutating func take(isFinal: Bool) -> [(sql: [UInt8], line: Int)] {
            let result = DelimiterScript.scan(pending, from: state, isFinal: isFinal, stopsAfterSQLMode: true)
            let statements = result.statements.map { (sql: Array(pending[$0.range]), line: $0.line) }
            pending.removeFirst(result.consumed)
            state = result.state
            return statements
        }
    }

    /// A line that holds one of the mysql client's own commands: for
    /// `"delimiter"`, `"DELIMITER $$"` → `$$`, `"delimiter ;"` → `;`,
    /// along with where that line ends. Requires a token after the
    /// keyword — a bare `"DELIMITER"` isn't a directive this can act on,
    /// so it's left for the surrounding statement to carry (harmlessly,
    /// as ordinary text). Only ever asked about a line that starts outside
    /// a string or comment, so a `DELIMITER` line quoted inside one is
    /// left alone.
    private static func commandLine(_ command: String, in bytes: [UInt8], lineStart: Int) -> (argument: [UInt8], lineEnd: Int)? {
        let count = bytes.count
        func isBlank(_ offset: Int) -> Bool {
            bytes[offset] == UInt8(ascii: " ") || bytes[offset] == UInt8(ascii: "\t")
        }

        var index = lineStart
        while index < count, isBlank(index) { index += 1 }
        for letter in command.utf8 {
            // `| 0x20` lowercases an ASCII letter.
            guard index < count, bytes[index] | 0x20 == letter else { return nil }
            index += 1
        }
        guard index < count, isBlank(index) else { return nil }
        while index < count, isBlank(index) { index += 1 }

        let tokenStart = index
        while index < count, bytes[index] > UInt8(ascii: " ") { index += 1 }
        guard index > tokenStart else { return nil }
        let token = Array(bytes[tokenStart..<index])

        while index < count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
        return (token, index)
    }
}
