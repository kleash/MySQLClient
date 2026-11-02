import XCTest
import MySQLNIO
@testable import MySQLMacClient

/// Regression coverage for a real bug found while manually testing against
/// the remote cPanel database: shared-hosting network/firewall layers
/// commonly kill idle TCP connections silently, and MySQLNIO only surfaces
/// this as `MySQLError.closed` on the *next* write. `KILL <id>` from a
/// second real connection reproduces exactly that server-side drop, without
/// a mock, so this proves `MySQLService`'s auto-reconnect-and-retry
/// actually recovers instead of just erroring out mid-session.
final class MySQLServiceReconnectTests: XCTestCase {
    var service: MySQLService!

    override func setUp() async throws {
        service = MySQLService()
        try await service.connect(
            host: TestDatabase.host,
            port: TestDatabase.port,
            username: TestDatabase.username,
            password: TestDatabase.password,
            database: "mysqlmacclient_test"
        )
        try await service.execute("DELETE FROM widgets")
        try await service.execute("""
            INSERT INTO widgets (name, quantity, created_at, notes) VALUES
            ('Bolt', 100, '2024-01-15 10:30:00', 'Standard bolt'),
            ('Nut', 250, '2024-02-20 14:00:00', NULL),
            ('Washer', NULL, NULL, 'Out of stock')
            """)
    }

    override func tearDown() async throws {
        try? await service.disconnect()
    }

    func testQueryTransparentlyReconnectsAfterServerKillsTheConnection() async throws {
        let idRows = try await service.query("SELECT CONNECTION_ID() AS id")
        guard let connectionID = idRows.first?.column("id")?.int else {
            return XCTFail("could not read CONNECTION_ID()")
        }
        let countBefore = try await service.query("SELECT COUNT(*) AS cnt FROM widgets").first?.column("cnt")?.int

        // A second, independent admin connection kills the first one from
        // the server side — this is what an idle-timing-out NAT/firewall
        // does to the client's socket, just triggered on demand.
        let killer = MySQLService()
        try await killer.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username, password: TestDatabase.password, database: "mysqlmacclient_test")
        try await killer.execute("KILL \(connectionID)")
        try await killer.disconnect()

        // Give the kill a moment to actually tear down the TCP connection
        // before we hit it again.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Without auto-reconnect this throws MySQLError.closed. With it,
        // this call transparently reconnects and this succeeds.
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM widgets")
        XCTAssertEqual(rows.first?.column("cnt")?.int, countBefore)

        let isConnected = await service.isConnected
        XCTAssertTrue(isConnected)
    }

    /// Through an SSH tunnel whose ssh isn't holding the port (this one was
    /// never opened), whatever is listening there would get the login: a
    /// dropped connection isn't opened again.
    func testDoesNotReconnectThroughATunnelThatIsDown() async throws {
        await service.setTunnel(SSHTunnel(settings: SSHSettings(host: "ssh.invalid", username: ""), proxy: nil, sshFolder: nil))
        let connectionID = try await service.query("SELECT CONNECTION_ID() AS id").first?.column("id")?.int
        let killer = MySQLService()
        try await killer.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username, password: TestDatabase.password, database: nil)
        try await killer.execute("KILL \(try XCTUnwrap(connectionID))")
        try await killer.disconnect()
        try await Task.sleep(nanoseconds: 300_000_000)

        do {
            _ = try await service.query("SELECT 1")
            XCTFail("reconnected through a tunnel that is down")
        } catch MySQLError.closed {}
        // Nor a backup's or restore's own connection, with the same login.
        do {
            let separate = try await service.openSeparateConnection()
            try? await separate.disconnect()
            XCTFail("opened a separate connection through a tunnel that is down")
        } catch MySQLError.closed {}
    }

    /// A connection closed before the server's greeting (as an SSH server
    /// does with a forward it refuses) ends the login with an error
    /// instead of leaving it waiting forever.
    func testLoginEndsWhenTheConnectionClosesBeforeTheServerAnswers() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length) == 0 && listen(listener, 1) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        XCTAssertTrue(listening)
        defer { close(listener) }
        Thread.detachNewThread { close(accept(listener, nil, nil)) }

        let refused = MySQLService()
        let started = Date()
        do {
            try await refused.connect(host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)),
                                      username: "root", password: nil, database: nil)
            XCTFail("logged in to a connection that closed")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        }
    }
}
