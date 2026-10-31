import XCTest
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
        XCTAssertEqual(rows.first?.column("cnt")?.int, 3)

        let isConnected = await service.isConnected
        XCTAssertTrue(isConnected)
    }
}
