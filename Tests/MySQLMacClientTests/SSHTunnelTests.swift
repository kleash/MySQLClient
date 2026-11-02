import XCTest
@testable import MySQLMacClient

/// Runs against the `ssh` profile of testenv/docker-compose.yml (started by
/// testenv/run-tests.sh): a MariaDB on an internal network that only the
/// SSH server can reach, the SSH server on 127.0.0.1:43322, and an HTTP
/// proxy that wants a login on 127.0.0.1:43380. Each test gives ssh a fresh
/// folder of its own, so nothing is written to ~/.ssh.
final class SSHTunnelTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var sshFolder: URL!
    private var tunnel: SSHTunnel?
    private var service: MySQLService?

    override func setUp() async throws {
        guard ["MYSQL_TEST_SSH_PORT", "MYSQL_TEST_SSH_KEY", "MYSQL_TEST_PROXY_PORT"].allSatisfy({ environment[$0] != nil }) else {
            throw XCTSkip("The SSH test servers aren't running (testenv/run-tests.sh starts them).")
        }
        sshFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sshFolder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? await service?.disconnect()
        tunnel?.close()
        if let sshFolder { try? FileManager.default.removeItem(at: sshFolder) }
    }

    private var direct: SSHSettings {
        SSHSettings(host: "127.0.0.1", port: Int(environment["MYSQL_TEST_SSH_PORT"]!)!, username: "tunnel",
                    keyFile: environment["MYSQL_TEST_SSH_KEY"]!)
    }

    /// The SSH server by the name the proxy knows it by.
    private var behindProxy: SSHSettings {
        SSHSettings(host: "ssh", port: 22, username: "tunnel", keyFile: environment["MYSQL_TEST_SSH_KEY"]!,
                    proxy: HTTPProxySettings(host: "127.0.0.1", port: Int(environment["MYSQL_TEST_PROXY_PORT"]!)!, username: "proxyuser"))
    }

    /// Opens a tunnel to the private database and connects through it.
    private func connect(_ settings: SSHSettings, proxyPassword: String = "proxy-test-password",
                         restartDelays: [TimeInterval] = SSHTunnel.defaultRestartDelays) async throws -> MySQLService {
        let proxy = settings.proxy.map {
            HTTPProxyConnector.Proxy(host: $0.host, port: $0.port, username: $0.username, password: proxyPassword)
        }
        let tunnel = SSHTunnel(settings: settings, proxy: proxy, sshFolder: sshFolder, restartDelays: restartDelays)
        self.tunnel = tunnel
        let localPort = try await tunnel.open(to: "private-mariadb", port: 3306)
        let service = MySQLService()
        self.service = service
        try await service.connect(host: "127.0.0.1", port: localPort, username: "root", password: nil, database: nil)
        return service
    }

    private func assertReachesThePrivateDatabase(_ service: MySQLService) async throws {
        let rows = try await service.textQuery("SELECT @@hostname AS host, 1 + 1 AS two")
        XCTAssertEqual(rows.first?.column("two")?.string, "2")
    }

    /// Ends this test's ssh, as a dropped network would.
    private func killSSH() throws {
        let killed = try Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-f", "--", sshFolder.path])
        killed.waitUntilExit()
        XCTAssertEqual(killed.terminationStatus, 0, "no ssh of this test's was running")
    }

    /// Someone else's key, remembered for the SSH server: its own then looks
    /// changed to ssh.
    private func rememberAnotherHostKey() throws {
        try "[127.0.0.1]:\(direct.port) ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n"
            .write(to: sshFolder.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
    }

    /// A form for the private database through the SSH server behind the
    /// proxy, that saves no password to the Keychain.
    @MainActor
    private func filledForm(_ store: ConnectionStore) -> ConnectionFormViewModel {
        let form = ConnectionFormViewModel(connectionStore: store)
        form.sshFolder = sshFolder
        form.name = "Private"
        form.host = "private-mariadb"
        form.port = "3306"
        form.username = "root"
        form.savePassword = false
        form.usesSSH = true
        form.sshHost = behindProxy.host
        form.sshPort = String(behindProxy.port)
        form.sshUsername = behindProxy.username
        form.sshKeyFile = behindProxy.keyFile
        form.usesProxy = true
        form.proxyHost = "127.0.0.1"
        form.proxyPort = environment["MYSQL_TEST_PROXY_PORT"]!
        form.proxyUsername = "proxyuser"
        form.proxyPassword = "proxy-test-password"
        return form
    }

    func testReachesADatabaseOnlyTheSSHServerCanReach() async throws {
        let service = try await connect(direct)
        try await assertReachesThePrivateDatabase(service)
        let knownHosts = try String(contentsOf: sshFolder.appendingPathComponent("known_hosts"), encoding: .utf8)
        XCTAssertTrue(knownHosts.contains("[127.0.0.1]:\(direct.port)"), "a first-seen host key is kept")
    }

    func testReachesItThroughAnHTTPProxyThatWantsALogin() async throws {
        let service = try await connect(behindProxy)
        try await assertReachesThePrivateDatabase(service)
    }

    func testSaysWhenTheProxyRefusesTheLogin() async throws {
        do {
            _ = try await connect(behindProxy, proxyPassword: "wrong")
            XCTFail("connected with a wrong proxy password")
        } catch let failure as SSHTunnel.Failure {
            // tinyproxy answers a wrong login with 401, others with 407 again.
            XCTAssertTrue(failure.message.contains("The proxy refused the connection to ssh:22"), failure.message)
            XCTAssertFalse(failure.message.contains(where: \.isNewline), "more than the proxy's status line: \(failure.message)")
        }
    }

    /// A login the proxy turned down is told from its other refusals: the
    /// relay stops asking then, since each restart of ssh would send it again.
    func testTellsALoginTheProxyTurnedDown() throws {
        let proxy = HTTPProxyConnector.Proxy(host: "127.0.0.1", port: behindProxy.proxy!.port, username: "proxyuser", password: "wrong")
        XCTAssertThrowsError(try HTTPProxyConnector.connect(through: proxy, to: "ssh", port: 22)) { error in
            XCTAssertEqual((error as? HTTPProxyConnector.Failure)?.loginRefused, true, "\(error)")
        }
    }

    func testSaysWhenTheServerRefusesTheKey() async throws {
        let otherKey = sshFolder.appendingPathComponent("other_key")
        let keygen = try Process.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: ["-q", "-t", "ed25519", "-N", "", "-f", otherKey.path])
        keygen.waitUntilExit()
        var settings = direct
        settings.keyFile = otherKey.path
        do {
            _ = try await connect(settings)
            XCTFail("connected with a key the server doesn't accept")
        } catch let failure as SSHTunnel.Failure {
            XCTAssertTrue(failure.message.contains("Permission denied"), failure.message)
        }
    }

    /// A host key that differs from the one remembered is someone else
    /// answering: ssh must refuse, not replace it.
    func testRefusesAServerWhoseHostKeyHasChanged() async throws {
        try rememberAnotherHostKey()
        do {
            _ = try await connect(direct)
            XCTFail("connected to a server whose host key changed")
        } catch let failure as SSHTunnel.Failure {
            XCTAssertTrue(failure.message.contains("Host key verification failed"), failure.message)
        }
    }

    /// ssh dies (the network dropped): a query meanwhile fails, and once the
    /// tunnel has started ssh again on the same port, the next one
    /// reconnects through it.
    func testComesBackAfterSSHEnds() async throws {
        let service = try await connect(direct)
        let tunnel = try XCTUnwrap(tunnel)
        try killSSH()
        let ended = Date().addingTimeInterval(5)
        while tunnel.isForwarding, Date() < ended { try await Task.sleep(for: .milliseconds(10)) }
        do {
            _ = try await service.textQuery("SELECT 1")
            XCTFail("a query got through while ssh was down")
        } catch {}
        try await Task.sleep(for: .seconds(3))
        try await assertReachesThePrivateDatabase(service)
        XCTAssertTrue(tunnel.isForwarding)
    }

    /// ssh can't come back (here the server's host key no longer matches):
    /// the tunnel stops starting it once its restarts have all failed (three
    /// short ones here), and a query on it gets ssh's reason rather than a
    /// connection error.
    func testStopsStartingSSHAgainWhenItKeepsFailing() async throws {
        let service = try await connect(direct, restartDelays: [0.5, 0.5, 0.5])
        let tunnel = try XCTUnwrap(tunnel)
        await service.setTunnel(tunnel)
        try rememberAnotherHostKey()
        try killSSH()
        let givenUp = Date().addingTimeInterval(30)
        while tunnel.lastFailure == nil, Date() < givenUp { try await Task.sleep(for: .milliseconds(100)) }
        let reason = try XCTUnwrap(tunnel.lastFailure, "still starting ssh again").message
        XCTAssertTrue(reason.contains("Host key verification failed"), reason)
        do {
            _ = try await service.textQuery("SELECT 1")
            XCTFail("a query got through a tunnel that is down")
        } catch let failure as SSHTunnel.Failure {
            XCTAssertEqual(failure.message, reason)
        }
    }

    /// The connection form opens the tunnel, logs in through it, and saves
    /// the SSH and proxy settings with the connection.
    @MainActor
    func testConnectionFormConnectsThroughSSHAndTheProxy() async throws {
        let store = ConnectionStore(fileURL: sshFolder.appendingPathComponent("connections.json"))
        let form = filledForm(store)

        let connected = await form.connect()
        let session = try XCTUnwrap(connected, form.errorMessage ?? "")
        tunnel = session.tunnel
        service = session.mysqlService
        let rows = try await session.mysqlService.textQuery("SELECT 1 + 1 AS two")
        XCTAssertEqual(rows.first?.column("two")?.string, "2")
        XCTAssertEqual(store.connections.first?.ssh, behindProxy)
    }

    /// Picking another saved connection while one connects (here while its
    /// tunnel opens) changes the form, not the connection under way: that
    /// logs in, and is saved, as the form was when Connect was clicked.
    @MainActor
    func testConnectingKeepsTheFormAsItWasWhenConnectWasClicked() async throws {
        let store = ConnectionStore(fileURL: sshFolder.appendingPathComponent("connections.json"))
        let other = ConnectionProfile(name: "Other", host: "other.invalid", port: 3307, username: "other", database: "other")
        store.add(other)
        let form = filledForm(store)

        let connecting = Task { await form.connect() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(form.isConnecting)
        form.loadForEditing(other)
        let connected = await connecting.value
        let session = try XCTUnwrap(connected, form.errorMessage ?? "")
        tunnel = session.tunnel
        service = session.mysqlService
        XCTAssertEqual(session.profile.name, "Private")
        XCTAssertEqual(session.profile.host, "private-mariadb")
        XCTAssertEqual(session.profile.username, "root")
        XCTAssertEqual(session.profile.ssh, behindProxy)
        XCTAssertEqual(store.connections.first { $0.id == other.id }, other)
        XCTAssertEqual(form.editingProfileId, other.id)
        let rows = try await session.mysqlService.textQuery("SELECT CURRENT_USER() AS user")
        XCTAssertEqual(rows.first?.column("user")?.string?.hasPrefix("root@"), true)
    }
}

/// The parts that need no server.
final class SSHTunnelArgumentTests: XCTestCase {
    func testArgumentsKeepTheHostFromBeingReadAsAnOption() {
        let arguments = SSHTunnel.arguments(
            settings: SSHSettings(host: "-oProxyCommand=touch /tmp/pwned", port: 22, username: "u", keyFile: "/keys/100%.pem"),
            localPort: 40000, databaseHost: "::1", databasePort: 3306, relayPort: nil, sshFolder: nil
        )
        XCTAssertEqual(arguments.suffix(2), ["--", "-oProxyCommand=touch /tmp/pwned"])
        XCTAssertTrue(arguments.contains("127.0.0.1:40000:[::1]:3306"))
        XCTAssertTrue(arguments.contains("/keys/100%%.pem"))
        // A connection of its own, never a ControlMaster's that close() can't end.
        XCTAssertTrue(arguments.contains("ControlPath=none"))
    }

    /// RFC 2617's own example: user Mufasa, GET /dir/index.html.
    func testDigestAnswerMatchesTheRFCExample() {
        let challenge = ["realm": "testrealm@host.com", "qop": "auth,auth-int", "nonce": "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                         "opaque": "5ccc069c403ebaf9f0171e9517f40e41"]
        let header = HTTPProxyConnector.digest(challenge, username: "Mufasa", password: "Circle Of Life", uri: "/dir/index.html",
                                               cnonce: "0a4f113b", method: "GET")
        XCTAssertTrue(header?.contains(#"response="6629fae49393a05397450978507c4ef1""#) ?? false, header ?? "nil")
    }

    /// RFC 7616's SHA-256 example (section 3.9.1).
    func testDigestAnswerMatchesTheRFC7616SHA256Example() {
        let challenge = ["realm": "http-auth@example.org", "qop": "auth, auth-int", "algorithm": "SHA-256",
                         "nonce": "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v", "opaque": "FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"]
        let header = HTTPProxyConnector.digest(challenge, username: "Mufasa", password: "Circle of Life", uri: "/dir/index.html",
                                               cnonce: "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ", method: "GET")
        XCTAssertTrue(header?.contains(#"response="753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1""#) ?? false,
                      header ?? "nil")
    }

    /// ssh is given the SSH folder's known_hosts in quotes, in an option
    /// that a double quote or a control character in the path would break.
    @MainActor
    func testRefusesAnSSHFolderWhosePathSSHWouldMisread() {
        let form = ConnectionFormViewModel(connectionStore: ConnectionStore(fileURL: URL(fileURLWithPath: "/dev/null")))
        for path in ["/Users/a\"b/.ssh", "/Users/a\nb/.ssh"] {
            form.errorMessage = nil
            form.useSSHFolder(URL(fileURLWithPath: path))
            XCTAssertNil(form.sshFolder, path)
            XCTAssertNotNil(form.errorMessage, path)
        }
    }
}
