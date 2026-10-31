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
/// reconnect finds the database where it was.
final class SSHTunnel: @unchecked Sendable {
    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    private let settings: SSHSettings
    private let proxy: HTTPProxyConnector.Proxy?
    private let sshFolder: URL?
    private let lock = NSLock()
    private var process: Process?
    private var relay: ProxyRelay?
    private var arguments: [String] = []
    private var isClosed = false
    private var restartDelay: TimeInterval = 1

    init(settings: SSHSettings, proxy: HTTPProxyConnector.Proxy?, sshFolder: URL?) {
        self.settings = settings
        self.proxy = proxy
        self.sshFolder = sshFolder
    }

    deinit {
        close()
    }

    /// Starts ssh and waits until the forward is listening; the local port
    /// that leads to `databaseHost:databasePort` as the SSH server sees it.
    func open(to databaseHost: String, port databasePort: Int) async throws -> Int {
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
        do {
            try await start()
        } catch {
            close()
            throw error
        }
        return localPort
    }

    func close() {
        lock.withLock {
            isClosed = true
            if process?.isRunning == true { process?.terminate() }
        }
        relay?.close()
    }

    /// ssh's arguments: no shell, no stdin, the forward, keepalives that
    /// notice a dead connection within 45 s, and the host after `--` so a
    /// host name can never be read as an option.
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
        errors.fileHandleForReading.readabilityHandler = { handle in log.append(handle.availableData) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in
            errors.fileHandleForReading.readabilityHandler = nil
            self?.ended()
        }
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
            if log.text.contains("Local forwarding listening on") { return }
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

    /// ssh ended. Unless the tunnel was closed, start it again after a
    /// pause that grows while it keeps failing (up to 30 s).
    private func ended() {
        lock.lock()
        let closed = isClosed
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        lock.unlock()
        guard !closed else { return }
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            if (try? await self.start()) != nil {
                self.lock.withLock { self.restartDelay = 1 }
            }
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
        let server: Int32
        do {
            server = try HTTPProxyConnector.connect(through: proxy, to: targetHost, port: targetPort)
        } catch {
            lock.lock()
            failure = error.localizedDescription
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
