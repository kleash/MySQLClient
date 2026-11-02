import AppKit
import Foundation
import MySQLNIO
import UniformTypeIdentifiers

/// Backs the "Restore..." sheet: runs a SQL file — a backup made by this
/// app, mysqldump or HeidiSQL — statement by statement, the way the `mysql`
/// client does.
///
/// The file is read a chunk at a time (`DelimiterScript.Splitter`), so a
/// dump of any size restores without being loaded into memory, and runs on
/// a connection of its own: its USE and SET statements must not change the
/// session the rest of the app uses, and that connection never reconnects
/// by itself, since the rest of the file would then run in a fresh session.
///
/// A file can't be restored all-or-nothing — CREATE and other DDL commit on
/// their own — so a restore that stops leaves what ran before it, and says
/// at which line it stopped.
@MainActor
final class DatabaseRestoreViewModel: ObservableObject {
    struct Progress: Equatable {
        var bytesRead: Int64
        var totalBytes: Int64
        var statementsRun: Int

        var percentage: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(bytesRead) / Double(totalBytes))
        }
    }

    /// A statement the server refused.
    struct StatementError: Identifiable, Equatable {
        let id = UUID()
        /// 1-based line of the file the statement starts on.
        let line: Int
        let statement: String
        let message: String
    }

    enum RestoreError: LocalizedError, Equatable {
        case notUTF8(line: Int)
        case stoppedAtError(line: Int)
        case connectionLost(line: Int)
        case cancelled(line: Int)
        case moreThanOneDatabase(line: Int)
        case statementTooLarge(line: Int)

        var errorDescription: String? {
            switch self {
            case .statementTooLarge(let line):
                return String(localized: "Stopped at line \(line): the statement there is 16 MB or larger, more than this restore can send to the server. The statements before it were restored; to restore the whole file, use the mysql client.")
            case .moreThanOneDatabase(let line):
                return String(localized: "Stopped at line \(line), where the file moves on to another database: restored into one, their tables would overwrite each other. To restore each into its own database, turn on \"Use the database named in the file\". The statements before it were restored.")
            case .notUTF8(let line):
                return String(localized: "Line \(line) isn't UTF-8 text, so it can't be sent to the server unchanged. A mysqldump file made without --hex-blob can hold raw binary data like this: restore it with the mysql client, or make the dump with --hex-blob.")
            case .stoppedAtError(let line):
                return String(localized: "Stopped at line \(line) because of the error below. The statements before it were restored.")
            case .connectionLost(let line):
                return String(localized: "The connection to the server dropped at line \(line). The statements before it were restored.")
            case .cancelled(let line):
                return String(localized: "Stopped at line \(line). The statements before it were restored.")
            }
        }
    }

    /// The database the restore starts in, and unless
    /// `useDatabaseNamedInFile` is on the only one it touches.
    let database: DatabaseInfo
    @Published var inputFileURL: URL?
    /// Off (the default): everything goes into `database`. The file's own
    /// USE, CREATE DATABASE and DROP DATABASE statements are skipped, so it
    /// can't touch the database it was made from, and the character set and
    /// collation its CREATE and ALTER DATABASE set go to `database` instead
    /// (`intoChosenDatabase`). On: the file decides, starting in `database`,
    /// as `mysql <database> < file` would.
    @Published var useDatabaseNamedInFile = false {
        didSet { if !useDatabaseNamedInFile { usesExternalTool = false } }
    }
    @Published var stopOnFirstError = true
    /// Restore with the mysql client (or mariadb) instead of the built-in
    /// engine. Only with `useDatabaseNamedInFile` on, and turned off with
    /// it: the client runs the file as it is, its USE statements too.
    @Published var usesExternalTool = false
    /// The client that runs then (`locateExternalTool`), and once it has run,
    /// the one that did; nil if there's none.
    @Published private(set) var externalToolURL: URL?
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Progress?
    @Published private(set) var statementErrors: [StatementError] = []
    /// Why the last restore stopped before the end of the file, if it did.
    @Published private(set) var failure: RestoreError?
    @Published var errorMessage: String?
    @Published var didFinishSuccessfully = false

    /// How much of the file is read at a time. Tests lower it so statements
    /// are cut between reads everywhere.
    var readChunkSize = 1 << 20

    private let service: MySQLService
    private var restoreTask: Task<Void, Never>?

    init(service: MySQLService, database: DatabaseInfo) {
        self.service = service
        self.database = database
    }

    func chooseInputFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql"), .plainText].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inputFileURL = url
    }

    /// `isRunning` is set before the task starts, so a second click can't
    /// start a competing restore (same as `DatabaseBackupViewModel`).
    func startRestore() {
        guard !isRunning, inputFileURL != nil else { return }
        isRunning = true
        errorMessage = nil
        failure = nil
        statementErrors = []
        progress = nil
        restoreTask = Task { [self] in await performRestore() }
    }

    func cancelRestore() {
        restoreTask?.cancel()
    }

    /// What runs in place of `statement` when the file goes into `database`
    /// rather than its own (`useDatabaseNamedInFile` off). The file's own
    /// USE, DROP DATABASE and CREATE DATABASE (also inside mysqldump's
    /// `/*!40000 … */`) pick or replace the database it was made from, so
    /// they are skipped (`nil`); but the character set and collation a
    /// CREATE or ALTER DATABASE sets go to the current database, `database`,
    /// through an ALTER DATABASE without the name. So the copy gets them,
    /// as do its routines, triggers and events (mysqldump sets the database
    /// collation each was made under around it), and the original keeps
    /// its own. Anything else runs as it is.
    static func intoChosenDatabase(_ statement: String) -> String? {
        guard let match = statement.prefixMatch(of: databaseStatement) else { return statement }
        let verb = match.verb?.uppercased() ?? "USE"
        if verb == "ALTER", match.name == nil { return statement }
        let setsCharacterSet = match.settings.contains(/(?i)\b(CHARACTER|CHARSET|COLLATE)\b/)
        guard match.name != nil, verb == "ALTER" || (verb.hasPrefix("CREATE") && setsCharacterSet) else { return nil }
        return (match.opener ?? "") + "ALTER DATABASE " + match.settings
    }

    /// The database a USE, CREATE, DROP or ALTER DATABASE names, unquoted.
    static func databaseName(in statement: String) -> String? {
        guard let name = statement.prefixMatch(of: databaseStatement)?.name else { return nil }
        guard let quote = name.first, quote == "`" || quote == "\"" else { return String(name) }
        return name.dropFirst().dropLast().replacingOccurrences(of: "\(quote)\(quote)", with: "\(quote)")
    }

    private static let databaseStatement = #/
        (?i) (?<opener> /\*!\d* \s* )?
        (?: USE \b
          | (?<verb> CREATE (?: \s+ OR \s+ REPLACE )? | DROP | ALTER ) \s+ (?: DATABASE | SCHEMA ) \b
            (?: \s+ IF (?: \s+ NOT )? \s+ EXISTS \b | \s* /\*!\d* \s* IF \s+ NOT \s+ EXISTS \s* \*/ )? )
        \s* (?<name> `(?: [^`] | `` )*` | "(?: [^"] | "" )*"
                   | (?! (?: DEFAULT | CHARACTER | CHARSET | COLLATE | COMMENT | ENCRYPTION | READ ) \b ) [\w$]+ )?
        \s* (?<settings> (?s: .* ) )
        /#

    /// Called from the sheet's `.task`.
    func locateExternalTool() async {
        let isMariaDB = await service.serverVersion?.contains("MariaDB") ?? false
        externalToolURL = ExternalTool.locate(.client, configuredPath: SettingsStore.shared.settings.general.clientToolPath,
                                              preferMariaDB: isMariaDB)
    }

    private func performRestore() async {
        defer { isRunning = false; restoreTask = nil }
        guard let inputFileURL else { return }
        if usesExternalTool { return await restoreWithExternalTool(from: inputFileURL) }
        var target: MySQLService?
        var line = 0
        do {
            let file = try FileHandle(forReadingFrom: inputFileURL)
            defer { try? file.close() }
            let totalBytes = Int64((try? inputFileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let connection = try await service.openSeparateConnection()
            target = connection
            _ = try await connection.textQuery("USE \(try SchemaIntrospectionService.quotedIdentifier(database.name))")

            var splitter = DelimiterScript.Splitter()
            splitter.noBackslashEscapes = try await Self.hasNoBackslashEscapes(connection)
            var current = Progress(bytesRead: 0, totalBytes: totalBytes, statementsRun: 0)
            progress = current
            var reachedEnd = false
            var readSize = readChunkSize
            var statements: [(sql: [UInt8], line: Int)] = []
            var filesDatabase: String?
            repeat {
                // The splitter stops after a statement that mentions
                // sql_mode: what it holds after that is split the way the
                // server now reads backslashes, before more is read.
                if let last = statements.last, DelimiterScript.mentionsSQLMode(last.sql[...]) {
                    splitter.noBackslashEscapes = try await Self.hasNoBackslashEscapes(connection)
                    statements = reachedEnd ? splitter.finish() : splitter.feed(Data())
                } else {
                    let chunk = try file.read(upToCount: readSize) ?? Data()
                    reachedEnd = chunk.isEmpty
                    current.bytesRead += Int64(chunk.count)
                    statements = reachedEnd ? splitter.finish() : splitter.feed(chunk)
                    // The splitter scans an unfinished statement again from
                    // its start with each read; doubling the read until it
                    // ends keeps a statement far bigger than one read linear
                    // to scan.
                    readSize = statements.isEmpty ? readSize * 2 : readChunkSize
                }
                for statement in statements {
                    line = statement.line + 1
                    if Task.isCancelled { throw RestoreError.cancelled(line: line) }
                    // Strict: a lenient decode would turn bytes that aren't
                    // UTF-8 into U+FFFD and store that instead.
                    guard let text = String(bytes: statement.sql, encoding: .utf8) else {
                        throw RestoreError.notUTF8(line: line + Self.lineBreaksBeforeInvalidUTF8(in: statement.sql))
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !useDatabaseNamedInFile, let name = Self.databaseName(in: trimmed) {
                        // A second database would land on the first one's tables.
                        if let filesDatabase, name != filesDatabase { throw RestoreError.moreThanOneDatabase(line: line) }
                        filesDatabase = name
                    }
                    guard let sql = useDatabaseNamedInFile ? trimmed : Self.intoChosenDatabase(trimmed), !sql.isEmpty else { continue }
                    // shortcut: MySQLNIO sends a query as one packet, whose
                    // length has 3 bytes, so a statement of 16 MiB or more
                    // would reach the server cut short; refused until it
                    // splits packets as the mysql client does.
                    guard sql.utf8.count < 0xFF_FF_FE else { throw RestoreError.statementTooLarge(line: line) }
                    do {
                        _ = try await connection.textQuery(sql)
                        current.statementsRun += 1
                    } catch {
                        if case MySQLError.closed = error {
                            throw RestoreError.connectionLost(line: line)
                        }
                        let message = SQLConsoleViewModel.relocatingErrorLine(in: describe(error), by: statement.line)
                        statementErrors.append(StatementError(line: line, statement: String(sql.prefix(300)), message: message))
                        if stopOnFirstError { throw RestoreError.stoppedAtError(line: line) }
                    }
                }
                progress = current
            } while !reachedEnd || !statements.isEmpty

            if statementErrors.isEmpty {
                didFinishSuccessfully = true
                AnalyticsService.trackFeatureUsed("db_restore")
            } else {
                errorMessage = String(localized: "Finished with \(statementErrors.count) failed statements, listed below. Every other statement was restored.")
            }
        } catch let error as RestoreError {
            failure = error
            errorMessage = error.errorDescription
        } catch {
            errorMessage = describe(error)
            AnalyticsService.trackError(error, feature: "db_restore")
        }
        try? await target?.disconnect()
    }

    /// Line breaks ahead of the first byte of `bytes` that isn't UTF-8, so
    /// the error names the line that holds it.
    private static func lineBreaksBeforeInvalidUTF8(in bytes: [UInt8]) -> Int {
        var parser = Unicode.UTF8.ForwardParser()
        var iterator = bytes.makeIterator()
        var valid = 0
        while case .valid(let scalar) = parser.parseScalar(from: &iterator) { valid += scalar.count }
        return bytes[..<valid].count { $0 == UInt8(ascii: "\n") }
    }

    /// Whether the session's sql_mode has NO_BACKSLASH_ESCAPES, which the
    /// mysql client reads from the server's status to split a file.
    private static func hasNoBackslashEscapes(_ connection: MySQLService) async throws -> Bool {
        let mode = try await connection.textQuery("SELECT @@SESSION.sql_mode AS mode").first?.column("mode")?.string
        return mode?.contains("NO_BACKSLASH_ESCAPES") ?? false
    }

    /// The client reads the file as `pass` hands it over, a whole statement
    /// at a time, so whatever stops it — an error, Cancel, a file that
    /// can't be read — it has never been sent part of a statement it could
    /// run cut short. With `--force` it carries on past errors and still
    /// ends with exit status 0, so they're found in what it says.
    private func restoreWithExternalTool(from inputFileURL: URL) async {
        // Where the client splits the file unlike `DelimiterScript`, it runs
        // a USE the built-in engine would skip, so it can't keep the file in
        // `database`.
        guard useDatabaseNamedInFile else {
            errorMessage = String(localized: "The mysql client follows the file's own USE statements: turn on \"Use the database named in the file\" to restore with it.")
            return
        }
        let questionLines = ExternalTool.Locked<[Int]>([])
        // Every ERROR line, also past the 100 lines `run` keeps, and the line
        // of the first that says the connection dropped: carrying on, the
        // client doesn't reconnect, so every statement after it failed.
        let failures = ExternalTool.Locked(0)
        let lostAt = ExternalTool.Locked<Int?>(nil)
        do {
            let isMariaDB = await service.serverVersion?.contains("MariaDB") ?? false
            let tool = try await ExternalTool.find(.client, configuredPath: SettingsStore.shared.settings.general.clientToolPath,
                                                   preferMariaDB: isMariaDB)
            externalToolURL = tool.url
            let connection = try await service.externalToolConnection()
            let arguments = try tool.restoreArguments(database: database.name, stopOnError: stopOnFirstError, connection: connection)
            let totalBytes = Int64((try? inputFileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            progress = Progress(bytesRead: 0, totalBytes: totalBytes, statementsRun: 0)
            let chunkSize = readChunkSize
            let output = Pipe()
            let messages = Self.fileLines(in: try await tool.run(arguments, optionFile: connection.optionFile, input: { input in
                // The client has its own copy by now: without this one, what
                // `pass` reads ends when the client does.
                try? output.fileHandleForWriting.close()
                try Self.pass(inputFileURL, to: input, output: output.fileHandleForReading,
                              chunkSize: chunkSize, questionLines: questionLines) { sent in
                    Task { @MainActor in
                        guard self.isRunning else { return }
                        self.progress = Progress(bytesRead: sent.bytesRead, totalBytes: totalBytes, statementsRun: sent.statementsRun)
                    }
                }
            }, output: output.fileHandleForWriting, onErrorLine: { line in
                guard line.hasPrefix("ERROR ") else { return }
                failures.mutate { $0 += 1 }
                if lostAt.value == nil, let lost = line.prefixMatch(of: /ERROR 20(?:06|13) \(\w+\) at line (\d+)/) {
                    lostAt.value = Int(lost.1)
                }
            }), questionLines: questionLines.value)
            if let line = lostAt.value {
                let lost = RestoreError.connectionLost(line: Self.fileLine(line, questionLines: questionLines.value))
                failure = lost
                errorMessage = (lost.errorDescription ?? "") + "\n" + messages
            } else if failures.value > 100 {
                errorMessage = String(localized: "\(tool.name) reported \(failures.value) failed statements; it restored every other statement. Its first 100 messages:\n\(messages)")
            } else if failures.value > 0 {
                errorMessage = String(localized: "\(tool.name) reported errors; it restored every other statement:\n\(messages)")
            } else {
                didFinishSuccessfully = true
                AnalyticsService.trackFeatureUsed("db_restore")
            }
        } catch is CancellationError {
            errorMessage = String(localized: "Stopped. What the client had already run stays restored.")
        } catch {
            errorMessage = Self.fileLines(in: describe(error), questionLines: questionLines.value)
            AnalyticsService.trackError(error, feature: "db_restore")
        }
    }

    /// The client's messages with the line each error names given as the
    /// file's, its own errors (without a code) too.
    nonisolated static func fileLines(in messages: String, questionLines: [Int]) -> String {
        messages.replacing(/(?m)^(ERROR (?:\d+ \(\w+\) )?at line )(\d+)/) { match in
            "\(match.output.1)\(fileLine(Int(match.output.2) ?? 0, questionLines: questionLines))"
        }
    }

    /// The file's line for one the client names: every question `pass`
    /// asked took two lines, after the line `questionLines` holds.
    private nonisolated static func fileLine(_ line: Int, questionLines: [Int]) -> Int {
        line - 2 * questionLines.count { $0 < line }
    }

    /// Writes the file to `input` up to the end of its last whole statement
    /// read so far (where `DelimiterScript.scan` says that is). `progress`
    /// gets the bytes read and statements sent, every megabyte and at the
    /// end.
    ///
    /// The client splits at a delimiter of the app's own, set before the
    /// file starts: each statement the scan finds goes to it ended by that
    /// token, and of what's between statements only the line breaks, so it
    /// never sees the file's DELIMITER lines. Following those, the client
    /// had read `DELIMITER ;` in a file with Windows line breaks as ";\r",
    /// and split a question at a file's `DELIMITER @@`.
    ///
    /// The file is split the way the client's session reads backslashes,
    /// as `performRestore` splits it: the client is asked when it starts and
    /// after each statement that mentions sql_mode, by a SELECT whose answer
    /// comes back on `output`, its standard output. Split the other way, a
    /// string that a routine made under NO_BACKSLASH_ESCAPES ends with a
    /// backslash ('C:\') ran on into the statements after it, and what
    /// `pass` puts between statements landed inside one. The client runs a
    /// line only once it has all of it, so each question takes two lines of
    /// its own, after the line `questionLines` gets, as the client numbers
    /// it (`fileLines`).
    nonisolated static func pass(_ fileURL: URL, to input: FileHandle, output: FileHandle,
                                 chunkSize: Int, questionLines: ExternalTool.Locked<[Int]>, progress: (Progress) -> Void) throws {
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }
        // Everything the client prints is read as it comes, so what the
        // file's own SELECTs print can't fill the pipe and stop it; only the
        // answers are kept.
        let marker = UUID().uuidString
        let answer = ExternalTool.Locked<Bool?>(nil)
        let answered = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var unfinished = Data()
            // What has come so far (`read(upToCount:)` would wait for all of
            // the count), and nothing once the client has ended.
            var data = output.availableData
            while !data.isEmpty {
                unfinished.append(data)
                while let end = unfinished.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = unfinished[unfinished.startIndex..<end]
                    unfinished = unfinished[(end + 1)...]
                    if line.starts(with: marker.utf8) {
                        answer.value = line.last == UInt8(ascii: "1")
                        answered.signal()
                    }
                }
                data = output.availableData
            }
            answered.signal()  // The client has ended, and won't answer.
        }
        // 15 bytes, the longest delimiter the client takes.
        let token = UUID().uuidString.filter(\.isHexDigit).prefix(15)
        func noBackslashEscapes(after state: DelimiterScript.ScanState) throws -> Bool {
            // The first question sets the delimiter, on the line the others
            // leave empty.
            let lead = questionLines.value.isEmpty ? "DELIMITER \(token)\n" : "\n"
            questionLines.value.append(state.line + 1 + 2 * questionLines.value.count)
            answer.value = nil
            let question = lead + "SELECT CONCAT('\(marker)', FIND_IN_SET('NO_BACKSLASH_ESCAPES', @@SESSION.sql_mode) > 0)\(token)\n"
            try input.write(contentsOf: Array(question.utf8))
            answered.wait()
            guard let value = answer.value else { throw POSIXError(.EPIPE) }
            return value
        }
        func lineBreaks(in bytes: ArraySlice<UInt8>) -> [UInt8] {
            Array(repeating: UInt8(ascii: "\n"), count: bytes.count { $0 == UInt8(ascii: "\n") })
        }

        var pending: [UInt8] = []
        var state = DelimiterScript.ScanState()
        state.noBackslashEscapes = try noBackslashEscapes(after: state)
        var sent = Progress(bytesRead: 0, totalBytes: 0, statementsRun: 0)
        var reported: Int64 = 0
        var readSize = chunkSize
        var reachedEnd = false
        var asked = false
        repeat {
            // After a statement that mentions sql_mode, what's left is split
            // the way the client now reads backslashes, before more is read.
            if !asked {
                let chunk = try file.read(upToCount: readSize) ?? Data()
                reachedEnd = chunk.isEmpty
                // The client drops a byte order mark only from the first line
                // it reads, which is the first question's.
                pending.append(contentsOf: sent.bytesRead == 0 && chunk.starts(with: [0xEF, 0xBB, 0xBF]) ? chunk.dropFirst(3) : chunk)
                sent.bytesRead += Int64(chunk.count)
            }
            let scanned = DelimiterScript.scan(pending, from: state, isFinal: reachedEnd, stopsAfterSQLMode: true)
            var whole: [UInt8] = []
            var copied = 0
            for statement in scanned.statements {
                whole += lineBreaks(in: pending[copied..<statement.range.lowerBound]) + pending[statement.range] + Array(token.utf8)
                copied = statement.range.upperBound
            }
            whole += lineBreaks(in: pending[copied..<scanned.consumed])
            try input.write(contentsOf: whole)
            asked = scanned.statements.last.map { DelimiterScript.mentionsSQLMode(pending[$0.range]) } ?? false
            pending.removeFirst(scanned.consumed)
            state = scanned.state
            if asked { state.noBackslashEscapes = try noBackslashEscapes(after: state) }
            sent.statementsRun += scanned.statements.count
            if reachedEnd || sent.bytesRead - reported >= 1 << 20 {
                reported = sent.bytesRead
                progress(sent)
            }
            // As in `performRestore`: a statement far bigger than one read
            // stays linear to scan.
            readSize = scanned.statements.isEmpty ? readSize * 2 : chunkSize
        } while !reachedEnd || asked
    }

    private func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "\(mysqlError)"
        }
        return error.localizedDescription
    }
}
