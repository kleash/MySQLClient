import XCTest
import MySQLNIO
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP), not a mock — see
/// MySQLClient.md's validation plan.
final class MySQLServiceRawQueryTests: XCTestCase {
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

    func testRawQuerySelectReturnsRowsAndNoAffectedCount() async throws {
        let result = try await service.rawQuery("SELECT name, quantity FROM widgets ORDER BY name ASC")
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows.first?.column("name")?.string, "Bolt")
        XCTAssertNil(result.affectedRows, "a SELECT never produces an affected-row count")
    }

    /// A `SELECT` that matches nothing is still a result set, and has to
    /// survive as one — with its columns — all the way up. Dropping it
    /// (which is what filtering empty row-groups used to do) left the query
    /// console unable to tell it apart from an `INSERT`/`USE`, so it fell
    /// back to showing whatever the grid held before.
    func testRawQueryEmptySelectKeepsItsColumns() async throws {
        let result = try await service.rawQuery("SELECT name, quantity FROM widgets WHERE name = 'nothing matches this'")
        XCTAssertEqual(result.resultSets.count, 1, "an empty SELECT is still one result set")
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(
            result.resultSets.first?.columns.map(\.name),
            ["name", "quantity"],
            "the columns the server announced must survive having no rows"
        )
        XCTAssertNil(result.affectedRows, "a SELECT never produces an affected-row count")
    }

    /// The other half of the distinction above: a statement that genuinely
    /// returns no result set contributes no entry at all.
    func testRawQueryWriteProducesNoResultSet() async throws {
        let result = try await service.rawQuery("UPDATE widgets SET quantity = quantity WHERE name = 'nothing matches this'")
        XCTAssertTrue(result.resultSets.isEmpty, "a write announces no columns, so there is no result set")
        XCTAssertEqual(result.affectedRows, 0)
    }

    func testRawQueryUpdateReturnsAffectedCountAndNoRows() async throws {
        let result = try await service.rawQuery("UPDATE widgets SET quantity = 500 WHERE name = 'Bolt'")
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.affectedRows, 1)

        let check = try await service.query("SELECT quantity FROM widgets WHERE name = 'Bolt'")
        XCTAssertEqual(check.first?.column("quantity")?.int, 500)
    }

    /// `USE db_name` is rejected by the prepared-statement protocol
    /// (`conn.query(_:_:)`, which `rawQuery` otherwise always uses, even
    /// with no binds) with `ER_UNSUPPORTED_PS` ("This command is not
    /// supported in the prepared statement protocol yet") — `rawQuery`
    /// must retry it onto the plain-text `simpleQuery` path instead, the
    /// same way the real `mysql` CLI sends it.
    func testRawQueryRunsUseStatementViaThePlainTextProtocol() async throws {
        let result = try await service.rawQuery("USE `mysqlmacclient_test`")
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertNil(result.affectedRows)
    }

    /// `CREATE`/`DROP PROCEDURE` hit the exact same `ER_UNSUPPORTED_PS`
    /// rejection as `USE` — this is the regression test for a real
    /// user-reported case (writing a stored procedure by hand in the query
    /// console), confirming the fix generalizes to *any* statement MySQL
    /// rejects from the prepared-statement protocol, not just `USE`.
    /// `CALL`ing the procedure back exercises the normal, still-prepared
    /// path; the tests below cover procedures that return result sets.
    func testRawQueryRunsCreateAndDropProcedureViaThePlainTextProtocol() async throws {
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS raw_query_test_proc")

        let created = try await service.rawQuery("""
            CREATE PROCEDURE raw_query_test_proc(IN newQuantity INT)
            BEGIN
                UPDATE widgets SET quantity = newQuantity WHERE name = 'Bolt';
            END
            """)
        XCTAssertTrue(created.rows.isEmpty)

        _ = try await service.rawQuery("CALL raw_query_test_proc(321)")
        let check = try await service.query("SELECT quantity FROM widgets WHERE name = 'Bolt'")
        XCTAssertEqual(check.first?.column("quantity")?.int, 321)

        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS raw_query_test_proc")
    }

    /// `CALL`ing a procedure whose body runs a `SELECT` used to fail with
    /// `ER_SP_BADSELECT` ("can't return a result set in the given context")
    /// because upstream MySQLNIO never requests `CLIENT_MULTI_RESULTS` in
    /// its handshake. This app now depends on a fork that does (see
    /// `Package.swift`), so this must work.
    func testRawQueryCallsProcedureThatReturnsAResultSet() async throws {
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS raw_query_test_select_proc")
        _ = try await service.rawQuery("""
            CREATE PROCEDURE raw_query_test_select_proc()
            BEGIN
                SELECT name FROM widgets WHERE name = 'Bolt';
            END
            """)

        let result = try await service.rawQuery("CALL raw_query_test_select_proc()")
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows.first?.column("name")?.string, "Bolt")

        // The connection must stay usable afterwards — requesting
        // `CLIENT_MULTI_RESULTS` without draining the follow-up result sets
        // desyncs the protocol, which showed up as the *next* query hanging
        // rather than as an error here.
        let followUp = try await service.rawQuery("SELECT 42 AS answer")
        XCTAssertEqual(followUp.rows.first?.column("answer")?.int, 42)

        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS raw_query_test_select_proc")
    }

    /// A procedure with *two* `SELECT`s is the case that exposed why the
    /// capability flag alone isn't enough: the driver stopped after the
    /// first result set and left the rest on the wire, so this call
    /// succeeded but every later query on that connection hung. Both
    /// result sets must come back — kept apart, not merged — and the
    /// connection must survive.
    func testRawQueryCallsProcedureReturningTwoResultSetsWithoutDesync() async throws {
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS raw_query_test_two_selects")
        _ = try await service.rawQuery("""
            CREATE PROCEDURE raw_query_test_two_selects()
            BEGIN
                SELECT name FROM widgets WHERE name = 'Bolt';
                SELECT quantity FROM widgets WHERE name = 'Nut';
            END
            """)

        let result = try await service.rawQuery("CALL raw_query_test_two_selects()")
        XCTAssertEqual(result.resultSets.count, 2, "both result sets should arrive, kept separate")
        XCTAssertEqual(result.resultSets.first?.rows.first?.column("name")?.string, "Bolt")
        XCTAssertEqual(result.resultSets.last?.rows.first?.column("quantity")?.int, 250)
        XCTAssertEqual(result.rows.count, 1, "`rows` is the first result set")

        let followUp = try await service.rawQuery("SELECT 7 AS answer")
        XCTAssertEqual(followUp.rows.first?.column("answer")?.int, 7)

        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS raw_query_test_two_selects")
    }

    func testRawQuerySyntaxErrorThrows() async throws {
        do {
            _ = try await service.rawQuery("SELEKT * FROM widgets")
            XCTFail("expected a syntax error to be thrown")
        } catch {
            // Any thrown error is acceptable proof the bad SQL wasn't silently accepted.
        }
    }
}
