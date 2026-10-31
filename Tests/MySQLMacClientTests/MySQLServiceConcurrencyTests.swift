import XCTest
@testable import MySQLMacClient

/// Regression coverage for a real bug found while manually testing the app:
/// switching tables quickly closed the connection with "MySQL error:
/// Connection closed". Root cause was that `MySQLService` was an actor with
/// a single `await` per query — actors are reentrant, so a second call
/// could start sending a command on the wire while a prior call was still
/// suspended waiting for its response, desyncing MySQL's non-pipelined wire
/// protocol. The fix serializes access with a FIFO gate inside the actor;
/// these tests fire concurrent queries the way rapid table-switching does,
/// against the real local MariaDB — not a mock.
final class MySQLServiceConcurrencyTests: XCTestCase {
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
        try await service.disconnect()
    }

    func testConcurrentQueriesDoNotCloseTheConnection() async throws {
        let tables = ["widgets", "widget_logs_nopk", "tags"]

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                for table in tables {
                    group.addTask { [service] in
                        let rows = try await service!.query("SELECT * FROM `\(table)`")
                        return rows.count
                    }
                }
            }
            for try await _ in group {}
        }

        // The connection must still be usable after the storm — this is
        // exactly what failed before the fix ("Connection closed").
        let isConnected = await service.isConnected
        XCTAssertTrue(isConnected)
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM widgets")
        XCTAssertEqual(rows.first?.column("cnt")?.int, 3)
    }

    func testConcurrentSchemaIntrospectionDuringRapidTableSwitching() async throws {
        // Mirrors what actually happens in the UI: each table click spins up
        // a fresh TableDataViewModel whose `.load()` issues several
        // sequential queries (columns, keys, count, page) — and the old
        // view's in-flight queries may still be running when the new one
        // starts, since Swift Task cancellation doesn't abort an in-flight
        // NIO future.
        let introspection = SchemaIntrospectionService(service: service)
        let tables = ["widgets", "widget_logs_nopk", "tags", "widgets", "tags"]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for table in tables {
                group.addTask {
                    _ = try await introspection.columns(forTable: table, inDatabase: "mysqlmacclient_test")
                    _ = try await introspection.primaryKeyColumnNames(forTable: table, inDatabase: "mysqlmacclient_test")
                }
            }
            for try await _ in group {}
        }

        let isConnected = await service.isConnected
        XCTAssertTrue(isConnected)
    }
}
