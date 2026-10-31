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

        var errorDescription: String? {
            switch self {
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

    /// The database the file is restored into, unless
    /// `useDatabaseNamedInFile` is on.
    let database: DatabaseInfo
    @Published var inputFileURL: URL?
    /// Off (the default): everything goes into `database`, and the file's
    /// own USE, CREATE DATABASE and DROP DATABASE statements are skipped, so
    /// it can't touch the database it was made from. On: the file decides,
    /// as it would with the `mysql` client.
    @Published var useDatabaseNamedInFile = false
    @Published var stopOnFirstError = true
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

    /// The file's own USE, CREATE, DROP and ALTER DATABASE statements
    /// (also inside mysqldump's `/*!40000 … */`), which pick, replace or
    /// change the database the file was made from. mysqldump writes
    /// `ALTER DATABASE <its database>` around a routine made under another
    /// database collation: run while restoring elsewhere, it would change
    /// the original.
    static func choosesDatabase(_ statement: String) -> Bool {
        statement.range(
            of: #"^(/\*!\d*\s*)?(USE|(CREATE|DROP|ALTER)\s+(DATABASE|SCHEMA))\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func performRestore() async {
        defer { isRunning = false; restoreTask = nil }
        guard let inputFileURL else { return }
        var target: MySQLService?
        var line = 0
        do {
            let file = try FileHandle(forReadingFrom: inputFileURL)
            defer { try? file.close() }
            let totalBytes = Int64((try? inputFileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let connection = try await service.openSeparateConnection()
            target = connection
            if !useDatabaseNamedInFile {
                _ = try await connection.textQuery("USE \(try SchemaIntrospectionService.quotedIdentifier(database.name))")
            }

            var splitter = DelimiterScript.Splitter()
            splitter.noBackslashEscapes = try await Self.hasNoBackslashEscapes(connection)
            var current = Progress(bytesRead: 0, totalBytes: totalBytes, statementsRun: 0)
            progress = current
            var reachedEnd = false
            var readSize = readChunkSize
            var statements: [(sql: [UInt8], line: Int)] = []
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
                        throw RestoreError.notUTF8(line: line)
                    }
                    let sql = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if sql.isEmpty || (!useDatabaseNamedInFile && Self.choosesDatabase(sql)) { continue }
                    do {
                        _ = try await connection.textQuery(sql)
                        current.statementsRun += 1
                    } catch {
                        if case MySQLError.closed = error {
                            throw RestoreError.connectionLost(line: line)
                        }
                        statementErrors.append(StatementError(line: line, statement: String(sql.prefix(300)), message: describe(error)))
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

    /// Whether the session's sql_mode has NO_BACKSLASH_ESCAPES, which the
    /// mysql client reads from the server's status to split a file.
    private static func hasNoBackslashEscapes(_ connection: MySQLService) async throws -> Bool {
        let mode = try await connection.textQuery("SELECT @@SESSION.sql_mode AS mode").first?.column("mode")?.string
        return mode?.contains("NO_BACKSLASH_ESCAPES") ?? false
    }

    private func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "\(mysqlError)"
        }
        return error.localizedDescription
    }
}
