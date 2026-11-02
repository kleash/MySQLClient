import Darwin
import Foundation

/// Reaches a database that only an SSH server can reach: runs macOS's own
/// `/usr/bin/ssh` with a local port forward, and the app connects to that
/// port on 127.0.0.1 as if the database were local.
///
/// ssh logs in with a key file or the keys ssh-agent and the SSH folder
/// offer (never a password prompt: it runs with BatchMode), trusts a host
/// key the first time it sees it, and refuses one that has changed. An
/// HTTP proxy in front of the SSH server is reached through `ProxyRelay`,
/// which keeps the proxy's password in this process.
///
/// If ssh exits while the tunnel is open (the network dropped, the server
/// restarted), it's started again on the same port, so `MySQLService`'s
/// reconnect finds the database where it was. Until it listens again
/// `isForwarding` is false: another program could have the port meanwhile.
/// After about two minutes of failed restarts it stops, and keeps ssh's
/// reason.
final class SSHTunnel: @unchecked Sendable {
    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The pauses before each restart of an ssh that dropped, while the
    /// restarts keep failing: about two minutes in all, time for a laptop to
    /// wake up or its Wi-Fi to come back.
    static let defaultRestartDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30, 30]

    /// Every tunnel not yet freed, so quitting can end their ssh, which
    /// would otherwise outlive the app.
    nonisolated(unsafe) private static let all = NSHashTable<SSHTunnel>.weakObjects()
    private static let allLock = NSLock()

    private let settings: SSHSettings
    private let proxy: HTTPProxyConnector.Proxy?
    private let sshFolder: URL?
    private let restartDelays: [TimeInterval]
    private let lock = NSLock()
    private var process: Process?
    private var relay: ProxyRelay?
    private var arguments: [String] = []
    private var isClosed = false
    private var isAccessingFolder = false
    private var forwardIsUp = false
    private var failure: Failure?

    init(settings: SSHSettings, proxy: HTTPProxyConnector.Proxy?, sshFolder: URL?,
         restartDelays: [TimeInterval] = defaultRestartDelays) {
        self.settings = settings
        self.proxy = proxy
        self.sshFolder = sshFolder
        self.restartDelays = restartDelays
        Self.allLock.withLock { Self.all.add(self) }
    }

    deinit {
        close()
    }

    /// Whether ssh's forward is listening: not from when ssh ends until a
    /// restart has it listening again, nor once the tunnel has given up.
    var isForwarding: Bool { lock.withLock { forwardIsUp } }

    /// ssh's reason, once every restart in a row has failed and the tunnel
    /// has stopped starting it.
    var lastFailure: Failure? { lock.withLock { failure } }

    /// Ends every tunnel's ssh, for quitting.
    static func closeAll() {
        allLock.withLock { all.allObjects }.forEach { $0.close() }
    }

    /// Starts ssh and waits until the forward is listening; the local port
    /// that leads to `databaseHost:databasePort` as the SSH server sees it.
    func open(to databaseHost: String, port databasePort: Int) async throws -> Int {
        // In the App Sandbox ssh, a child of this process, can open the SSH
        // folder only while this process is accessing it, and loses it the
        // moment that stops: so from before the arguments look into it
        // until close(), across every restart.
        isAccessingFolder = sshFolder?.startAccessingSecurityScopedResource() ?? false
        do {
            if let proxy {
                relay = try ProxyRelay(proxy: proxy, targetHost: settings.host, targetPort: settings.port)
            }
            let localPort = try Self.freeLocalPort()
            arguments = Self.arguments(
                settings: settings,
                localPort: localPort,
                databaseHost: databaseHost,
                databasePort: databasePort,
                relayPort: relay?.port,
                sshFolder: sshFolder
            )
            try await start()
            return localPort
        } catch {
            close()
            throw error
        }
    }

    func close() {
        // Only the first call: deinit calls this again, and the folder's
        // access has to be given back exactly once.
        let closing = lock.withLock {
            defer { isClosed = true }
            forwardIsUp = false
            if process?.isRunning == true { process?.terminate() }
            return !isClosed
        }
        guard closing else { return }
        relay?.close()
        if isAccessingFolder { sshFolder?.stopAccessingSecurityScopedResource() }
    }

    /// ssh's arguments: no shell, no stdin, the forward, a connection of its
    /// own (one shared through a ControlMaster would outlive close()),
    /// keepalives that notice a dead connection within 45 s, and the host
    /// after `--` so a host name can never be read as an option.
    static func arguments(
        settings: SSHSettings,
        localPort: Int,
        databaseHost: String,
        databasePort: Int,
        relayPort: Int?,
        sshFolder: URL?
    ) -> [String] {
        let target = databaseHost.contains(":") ? "[\(databaseHost)]" : databaseHost
        var arguments = [
            "-N", "-n", "-v",
            "-L", "127.0.0.1:\(localPort):\(target):\(databasePort)",
            "-p", String(settings.port),
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ControlPath=none",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        if !settings.username.isEmpty {
            arguments += ["-l", settings.username]
        }
        // ssh reads `%` in a key path as the start of a token.
        func pathValue(_ path: String) -> String { path.replacingOccurrences(of: "%", with: "%%") }
        if !settings.keyFile.isEmpty {
            arguments += ["-i", pathValue(settings.keyFile), "-o", "IdentitiesOnly=yes"]
        }
        if let relayPort {
            arguments += ["-o", "ProxyCommand=/usr/bin/nc 127.0.0.1 \(relayPort)"]
        }
        // In the App Sandbox ssh can't open ~/.ssh, only the folder the
        // user granted: its config, known_hosts and default keys by name.
        if let sshFolder {
            let config = sshFolder.appendingPathComponent("config").path
            arguments += ["-F", FileManager.default.fileExists(atPath: config) ? config : "/dev/null"]
            arguments += ["-o", "UserKnownHostsFile=\"\(pathValue(sshFolder.appendingPathComponent("known_hosts").path))\""]
            if settings.keyFile.isEmpty {
                for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
                    let key = sshFolder.appendingPathComponent(name).path
                    if FileManager.default.fileExists(atPath: key) { arguments += ["-i", pathValue(key)] }
                }
            }
        }
        return arguments + ["--", settings.host]
    }

    // MARK: - Running ssh

    private func start() async throws {
        let errors = Pipe()
        let log = Log()
        // To the end of what ssh wrote, which can come after it has ended:
        // its last words say why.
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            log.append(data)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in self?.ended() }
        // Under the lock, so a close() can't come between the check and
        // the start and leave this ssh running.
        try lock.withLock {
            guard !isClosed else { throw CancellationError() }
            self.process = process
            try process.run()
        }

        // `ssh -v` says when the forward is listening. Not found by
        // connecting to it: each such probe would reach the database as an
        // aborted connection, and enough of those get the SSH server's
        // address blocked (max_connect_errors) for everyone using it.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if log.text.contains("Local forwarding listening on") {
                // Under the lock with ended(), so an ssh that has ended
                // meanwhile isn't taken for one that's up.
                let isUp = lock.withLock {
                    forwardIsUp = process.isRunning && !isClosed
                    return forwardIsUp
                }
                if isUp { return }
            }
            if !process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))  // the last of its output
                throw Failure(message: failureMessage(log.text))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        throw Failure(message: String(localized: "The SSH connection didn't open within 45 seconds."))
    }

    /// What went wrong, in ssh's own words (its error lines, without the
    /// -v detail), and the proxy's when it was the proxy.
    private func failureMessage(_ log: String) -> String {
        if let proxyFailure = relay?.lastFailure { return proxyFailure }
        let lines = log.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("debug1:") && !$0.hasPrefix("OpenSSH_") && !$0.contains("Authenticated") }
        let detail = lines.suffix(3).joined(separator: "\n")
        return String(localized: "The SSH connection to \(settings.host) failed: \(detail.isEmpty ? String(localized: "ssh ended without saying why.") : detail)")
    }

    /// ssh ended. If it was forwarding and the tunnel is open, it's started
    /// again after each of `restartDelays` while it keeps failing; then the
    /// tunnel stays down and keeps ssh's reason.
    private func ended() {
        let wasForwarding = lock.withLock {
            defer { forwardIsUp = false }
            return forwardIsUp  // never once closed
        }
        // One that never got that far failed to start: its start() says why.
        guard wasForwarding else { return }
        Task.detached { [weak self, restartDelays] in
            var last: Failure?
            for pause in restartDelays {
                try? await Task.sleep(for: .seconds(pause))
                do {
                    guard let self else { return }
                    return try await self.start()
                } catch is CancellationError {
                    return  // closed meanwhile
                } catch {
                    last = error as? Failure ?? Failure(message: error.localizedDescription)
                }
            }
            guard let self else { return }
            self.lock.withLock { self.failure = last }
        }
    }

    /// A port nothing on 127.0.0.1 is listening on.
    private static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: String(cString: strerror(errno))) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw Failure(message: String(cString: strerror(errno))) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// ssh's standard error, collected as it comes.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ more: Data) {
            lock.lock()
            data.append(more)
            if data.count > 65536 { data = data.suffix(32768) }
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Listens on 127.0.0.1 for ssh's ProxyCommand (`nc 127.0.0.1 <port>`) and
/// carries each connection on through the HTTP proxy to the SSH server, so
/// the proxy's password never leaves this process — not on a command line,
/// not in an environment.
final class ProxyRelay: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let proxy: HTTPProxyConnector.Proxy
    private let targetHost: String
    private let targetPort: Int
    private let lock = NSLock()
    private var failure: String?
    private var loginRefused = false

    /// Why the proxy last refused a connection, if it did.
    var lastFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    init(proxy: HTTPProxyConnector.Proxy, targetHost: String, targetPort: Int) throws {
        self.proxy = proxy
        self.targetHost = targetHost
        self.targetPort = targetPort
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = fd >= 0 && withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard listening else {
            let message = String(cString: strerror(errno))
            if fd >= 0 { Darwin.close(fd) }
            throw SSHTunnel.Failure(message: message)
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func close() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return  // closed
            }
            Thread.detachNewThread { [self] in relay(client) }
        }
    }

    private func relay(_ client: Int32) {
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Once the proxy has turned the login down, asking again would only
        // send it again, at every restart of ssh: an account lockout.
        guard !lock.withLock({ loginRefused }) else {
            Darwin.close(client)
            return
        }
        let server: Int32
        do {
            server = try HTTPProxyConnector.connect(through: proxy, to: targetHost, port: targetPort)
        } catch {
            lock.lock()
            failure = error.localizedDescription
            loginRefused = (error as? HTTPProxyConnector.Failure)?.loginRefused == true
            lock.unlock()
            Darwin.close(client)
            return
        }
        // Either side ending ends both directions; the sockets are closed
        // only once neither thread uses them.
        let otherDirection = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Self.pump(from: client, to: server)
            shutdown(server, SHUT_RDWR)
            shutdown(client, SHUT_RDWR)
            otherDirection.signal()
        }
        Self.pump(from: server, to: client)
        shutdown(client, SHUT_RDWR)
        shutdown(server, SHUT_RDWR)
        otherDirection.wait()
        Darwin.close(server)
        Darwin.close(client)
    }

    /// Copies `source` to `destination` until either ends.
    private static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0,
                  buffer.withUnsafeBytes({ HTTPProxyConnector.writeAll(destination, UnsafeRawBufferPointer(rebasing: $0.prefix(count))) })
            else { return }
        }
    }
}
