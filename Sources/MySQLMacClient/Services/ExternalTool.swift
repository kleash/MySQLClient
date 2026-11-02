import Darwin
import Foundation

/// MySQL's or MariaDB's own command-line tools as the engine of a backup
/// (mysqldump, mariadb-dump) or a restore (mysql, mariadb), the way DataGrip
/// offers them, in place of the app's own.
///
/// A tool connects the way the app's connection does: the same host and
/// port (through an SSH tunnel, its local end), user and encryption. Its
/// password goes in an option file only this user can read, deleted when
/// the tool ends — never on its command line or in its environment, where
/// other processes can read it.
///
/// Options that differ between MySQL's and MariaDB's tools, and between
/// their versions, are taken from what the tool's own `--help` lists. The
/// rest every supported version has; one that's missing makes the tool
/// refuse to start, which is safer than leaving it out.
struct ExternalTool: Sendable {
    enum Kind: Sendable {
        case dump, client
    }

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// How to reach the server a `MySQLService` is connected to
    /// (`MySQLService.externalToolConnection`).
    struct Connection: Sendable {
        var host: String
        var port: Int
        var username: String
        var tls: TLSMode?
        /// The server's own name when `host` isn't it: an SSH tunnel's local end.
        var serverName: String?
        /// `optionFile(password:)`.
        var optionFile: String
    }

    let url: URL
    /// What `--help` prints.
    let help: String

    /// The App Sandbox hides programs installed outside the app, and the
    /// libraries they load, from the app and from whatever it runs.
    static let isAvailable = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil

    var name: String { url.lastPathComponent }

    /// Whether `--help` lists `--<option>`.
    func supports(_ option: String) -> Bool {
        help.range(of: "(?m)^\\s*(-., )?--\(option)(?![\\w-])", options: .regularExpression) != nil
    }

    // MARK: - Finding the tool

    /// Where the tools usually are: Homebrew on Apple silicon and on Intel
    /// (mysql-client isn't linked into bin, it has a folder of its own),
    /// Oracle's installer, MySQL Workbench, and XAMPP (MariaDB's). The
    /// folders that only MySQL's tools are in come first: Homebrew's
    /// mariadb also names its tools mysqldump and mysql, in its folder and
    /// in bin.
    private static let searchPaths = [
        "/opt/homebrew/opt/mysql-client/bin", "/opt/homebrew/opt/mysql/bin", "/usr/local/opt/mysql-client/bin", "/usr/local/opt/mysql/bin",
        "/usr/local/mysql/bin", "/Applications/MySQLWorkbench.app/Contents/MacOS",
        "/opt/homebrew/opt/mariadb/bin", "/opt/homebrew/bin", "/usr/local/opt/mariadb/bin", "/usr/local/bin", "/Applications/XAMPP/xamppfiles/bin",
    ]

    /// The tool at `configuredPath` (Settings), or else the first one found:
    /// for a MariaDB server MariaDB's own tool first, MySQL's otherwise,
    /// since each knows its own server's objects best.
    static func locate(_ kind: Kind, configuredPath: String, preferMariaDB: Bool) -> URL? {
        if !configuredPath.isEmpty { return URL(fileURLWithPath: configuredPath) }
        let names = kind == .dump ? ["mariadb-dump", "mysqldump"] : ["mariadb", "mysql"]
        for name in preferMariaDB ? names : names.reversed() {
            for directory in searchPaths where FileManager.default.isExecutableFile(atPath: "\(directory)/\(name)") {
                return URL(fileURLWithPath: "\(directory)/\(name)")
            }
        }
        return nil
    }

    /// The tool `locate` finds, with what it says about itself.
    static func find(_ kind: Kind, configuredPath: String, preferMariaDB: Bool) async throws -> ExternalTool {
        guard isAvailable else {
            throw Failure(message: String(localized: "The App Sandbox keeps this build from running command-line tools installed outside the app."))
        }
        guard let url = locate(kind, configuredPath: configuredPath, preferMariaDB: preferMariaDB) else {
            throw Failure(message: kind == .dump
                ? String(localized: "No mysqldump or mariadb-dump was found. Choose one in Settings ▸ General.")
                : String(localized: "No mysql or mariadb client was found. Choose one in Settings ▸ General."))
        }
        return ExternalTool(url: url, help: try await output(of: url, "--help"))
    }

    /// What the tool prints for `option`, without reading any option file.
    private static func output(of url: URL, _ option: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = url
                process.arguments = ["--no-defaults", option]
                let output = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                } catch {
                    return continuation.resume(throwing: Failure(message: String(localized: "Couldn't run \(url.path): \(error.localizedDescription)")))
                }
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    return continuation.resume(throwing: Failure(message: String(localized: "Couldn't run \(url.path): \(text)")))
                }
                continuation.resume(returning: text)
            }
        }
    }

    // MARK: - Arguments

    /// Where and how to connect, on the command line, which wins over any
    /// option file.
    func connectionArguments(_ connection: Connection) throws -> [String] {
        [
            // A host of "localhost" would otherwise mean the Unix socket.
            "--protocol=TCP",
            "--host=\(connection.host)",
            "--port=\(connection.port)",
            "--user=\(connection.username)",
            "--default-character-set=utf8mb4",
        ] + (try tlsArguments(connection))
    }

    /// The connection's encryption in the tool's own options, or a refusal
    /// where the tool can't be made to insist on it. Without encryption the
    /// tool doesn't check a certificate, which MariaDB's do by default from
    /// 11.4, so they'd refuse a server without TLS.
    private func tlsArguments(_ connection: Connection) throws -> [String] {
        guard let tls = connection.tls else { return supports("ssl-verify-server-cert") ? ["--skip-ssl-verify-server-cert"] : [] }
        if tls == .verifyCertificate, connection.serverName != nil {
            throw Failure(message: String(localized: "Through an SSH tunnel \(name) can only check the server's certificate against 127.0.0.1, not the server's own name, so it can't verify it. Use the built-in engine for this connection."))
        }
        if supports("ssl-mode") {
            // MySQL's client checks a certificate only against the authorities
            // in a file it's given: here the ones macOS ships.
            return tls == .required ? ["--ssl-mode=REQUIRED"] : ["--ssl-mode=VERIFY_IDENTITY", "--ssl-ca=/etc/ssl/cert.pem"]
        }
        if supports("ssl-verify-server-cert") {
            // MariaDB's can't be told to insist on encryption without checking
            // the certificate: `--ssl` alone carries on unencrypted when the
            // server has no TLS (MDEV-28634), so it's checked in both modes.
            return ["--ssl", "--ssl-verify-server-cert"]
        }
        throw Failure(message: String(localized: "\(name) has no option to insist on an encrypted connection, so it could connect unencrypted. Use the built-in engine for this connection."))
    }

    /// The whole database, read without locking a table, from one
    /// consistent snapshot of its InnoDB tables (other engines' are read as
    /// they are), with everything in it: routines, triggers and events,
    /// binary values in hex, and the CREATE DATABASE and USE that bring it
    /// back under its own name with its own character set. The file sets
    /// the time zone it was read in and the SQL mode that keeps an explicit
    /// id 0 itself. `--verbose` names each table as it's read.
    func dumpArguments(database: String, connection: Connection) throws -> [String] {
        var arguments = try connectionArguments(connection)
        arguments += ["--single-transaction", "--skip-lock-tables", "--routines", "--triggers", "--events", "--hex-blob",
                      "--no-tablespaces", "--verbose"]
        // MySQL's tools only: a dump for another server mustn't reset its
        // GTID history, and histograms are statistics the server rebuilds
        // (ANALYZE TABLE), read from a table MariaDB doesn't have.
        if supports("set-gtid-purged") { arguments.append("--set-gtid-purged=OFF") }
        if supports("column-statistics") { arguments.append("--column-statistics=0") }
        // `--`: a database named like an option is still a name.
        return arguments + ["--databases", "--", database]
    }

    /// The file exactly as it is: without `--binary-mode` the client turns
    /// a raw line break inside a string into a different one, refuses a NUL
    /// byte, and runs the file's `system` lines as shell commands. Comments
    /// are kept (MariaDB's client drops them, also those inside a routine's
    /// body), and a statement may be as big as the server takes. What it
    /// prints is written out after each statement, where
    /// `DatabaseRestoreViewModel.pass` waits for the answers it asks for.
    /// It starts in `database`, as `mysql <database> < file` does.
    func restoreArguments(database: String, stopOnError: Bool, connection: Connection) throws -> [String] {
        var arguments = try connectionArguments(connection)
        arguments += ["--binary-mode", "--comments", "--max-allowed-packet=1073741824", "--unbuffered"]
        if !stopOnError { arguments.append("--force") }
        // MariaDB's client writes out a failed statement before its error, and
        // a long one pushed the errors out of what `run` keeps.
        if supports("print-query-on-error") { arguments.append("--skip-print-query-on-error") }
        arguments.append("--database=\(database)")
        return arguments
    }

    /// A `[client]` option file with the password in double quotes, where
    /// `#` starts no comment and spaces are kept, escaped the way MySQL's
    /// and MariaDB's option-file reader unescapes it.
    static func optionFile(password: String?) -> String {
        guard let password, !password.isEmpty else { return "[client]\n" }
        let escaped = password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "[client]\npassword=\"\(escaped)\"\n"
    }

    // MARK: - Running

    /// Runs the tool with `optionFile` as the only option file it reads (so
    /// nothing in the user's own ~/.my.cnf or ~/.mylogin.cnf can change
    /// what's dumped or where it goes), in a folder of its own only this
    /// user can open, deleted once the tool has ended — also when it failed
    /// or was cancelled.
    /// Cancelling the task stops the tool.
    ///
    /// `input` writes what the tool reads, on a thread of its own started
    /// once the tool is running: a write waits while the tool is busy, and
    /// fails once it has ended. The tool writes to `output` (nowhere
    /// without), and each line it writes to standard error goes to
    /// `onErrorLine` as it comes. Returns the lines
    /// that aren't progress (`--verbose`'s start with "-- "); throws them
    /// in a `Failure` unless the tool ends with exit status 0, and else
    /// what `input` threw.
    func run(_ arguments: [String], optionFile: String, input: (@Sendable (FileHandle) throws -> Void)? = nil,
             output: FileHandle? = nil, onErrorLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let folder = try Self.makePrivateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let optionFileURL = folder.appendingPathComponent("client.cnf")
        try Self.writePrivately(optionFile, to: optionFileURL)

        let process = Process()
        process.executableURL = url
        process.arguments = ["--defaults-file=\(optionFileURL.path)"] + arguments
        // MySQL's tools read ~/.mylogin.cnf after the option file, and 8.0's
        // can't be told not to: its documented override names one that isn't there.
        process.environment = ProcessInfo.processInfo.environment.merging(["MYSQL_TEST_LOGIN_FILE": folder.appendingPathComponent("mylogin.cnf").path]) { $1 }
        let toTool = Pipe()
        process.standardInput = FileHandle.nullDevice
        if input != nil { process.standardInput = toTool }
        process.standardOutput = output ?? FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw Failure(message: String(localized: "Couldn't run \(url.path): \(error.localizedDescription)"))
        }
        Self.running.mutate { $0[folder] = process }
        defer { Self.running.mutate { $0[folder] = nil } }

        let fed = DispatchSemaphore(value: 0)
        let inputError = Locked<Error?>(nil)
        if let input {
            // A write to a tool that has ended then fails, instead of
            // SIGPIPE ending the app.
            _ = fcntl(toTool.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            Thread.detachNewThread {
                do { try input(toTool.fileHandleForWriting) } catch { inputError.value = error }
                try? toTool.fileHandleForWriting.close()
                fed.signal()
            }
        } else {
            fed.signal()
        }

        let messages = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    // Until the tool ends, which closes the pipe.
                    var messages: [String] = []
                    var unfinished = Data()
                    func take(_ line: Data) {
                        let text = String(decoding: line, as: UTF8.self)
                        onErrorLine?(text)
                        if !text.hasPrefix("-- "), messages.count < 100 { messages.append(text) }
                    }
                    // What has come so far, as `pass` reads: `read(upToCount:)`
                    // would wait for all of the count, and --verbose's progress with it.
                    while case let data = errors.fileHandleForReading.availableData, !data.isEmpty {
                        unfinished.append(data)
                        while let end = unfinished.firstIndex(of: UInt8(ascii: "\n")) {
                            take(unfinished[unfinished.startIndex..<end])
                            unfinished = unfinished[(end + 1)...]
                        }
                    }
                    if !unfinished.isEmpty { take(unfinished) }
                    exited.wait()
                    fed.wait()
                    continuation.resume(returning: messages.joined(separator: "\n"))
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let status = Int(process.terminationStatus)
            throw Failure(message: (process.terminationReason == .exit
                ? String(localized: "\(name) failed with exit status \(status).")
                : String(localized: "\(name) was ended by signal \(status).")) + "\n" + messages)
        }
        if let error = inputError.value { throw error }
        return messages
    }

    /// The tools running now, by their folders: quitting skips `run`'s own
    /// cleanup.
    private static let running = Locked<[URL: Process]>([:])

    /// Called when the app quits: ends each tool still running and deletes
    /// its folder, with the option file.
    static func endAll() {
        for (folder, process) in running.value {
            process.terminate()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A value two threads share.
    final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
    }

    /// A new folder in the temporary folder only this user can open
    /// (`mkdtemp` makes it 0700).
    private static func makePrivateFolder() throws -> URL {
        var template = Array("\(FileManager.default.temporaryDirectory.path)/mysqlclient-tool-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw Failure(message: String(cString: strerror(errno))) }
        return URL(fileURLWithPath: template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    /// Creates `url` for this user only to read and write — never a file
    /// that's already there, or one a link points to.
    private static func writePrivately(_ contents: String, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure(message: String(cString: strerror(errno))) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: Data(contents.utf8))
        try file.close()
    }
}
