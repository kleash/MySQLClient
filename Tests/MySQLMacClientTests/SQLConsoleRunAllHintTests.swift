import XCTest
import MySQLNIO
@testable import MySQLMacClient

/// Pure logic — no database, unlike `SQLConsoleViewModelTests`. Covers when
/// a `max_allowed_packet` failure should point the user at "Run All".
@MainActor
final class SQLConsoleRunAllHintTests: XCTestCase {
    /// The case that prompted this: a pasted dump that "Run" sends as one
    /// oversized packet, but "Run All" would send statement by statement.
    func testMultiStatementScriptGetsTheHint() {
        let dump = """
        CREATE TABLE `a` (`id` int);
        INSERT INTO `a` VALUES (1),(2),(3);
        INSERT INTO `a` VALUES (4),(5),(6);
        """
        XCTAssertNotNil(SQLConsoleViewModel.runAllHint(forFailedSQL: dump))
    }

    /// One statement that's simply too big on its own can't be split into
    /// anything smaller, so pointing at "Run All" would be a dead end.
    func testSingleOversizedStatementGetsNoHint() {
        let values = (1...5_000).map { "(\($0))" }.joined(separator: ",")
        XCTAssertNil(SQLConsoleViewModel.runAllHint(forFailedSQL: "INSERT INTO `a` VALUES \(values);"))
    }

    /// A trailing semicolon doesn't make a one-statement script look like
    /// two — otherwise almost every failure would carry a useless hint.
    func testSingleStatementWithTrailingSemicolonGetsNoHint() {
        XCTAssertNil(SQLConsoleViewModel.runAllHint(forFailedSQL: "SELECT * FROM `widgets`;"))
    }

    func testStatementWithNoTrailingSemicolonGetsNoHint() {
        XCTAssertNil(SQLConsoleViewModel.runAllHint(forFailedSQL: "SELECT * FROM `widgets`"))
    }

    /// Semicolons inside string literals aren't statement boundaries.
    func testSemicolonInsideAStringLiteralIsNotAStatementBoundary() {
        XCTAssertNil(SQLConsoleViewModel.runAllHint(forFailedSQL: "INSERT INTO `a` VALUES ('x;y');"))
    }

    // MARK: - Silent statement-by-statement retry

    private let syntaxError = MySQLError.invalidSyntax(
        "You have an error in your SQL syntax; ... near 'INSERT INTO `a`' at line 2"
    )

    /// The reported case: a pasted `CREATE TABLE` + `INSERT`s dump run with
    /// "Run". The connection doesn't negotiate multi-statements, so the
    /// server parses only the first statement and raises `ER_PARSE_ERROR`
    /// at the boundary — which mysql-nio surfaces as `.invalidSyntax`, not
    /// a `.server` packet. "Run" should just re-run it properly.
    func testMultiStatementDumpIsRetriedStatementByStatement() {
        let dump = """
        CREATE TABLE `a` (`id` int);
        INSERT INTO `a` VALUES (1),(2),(3);
        """
        XCTAssertTrue(SQLConsoleViewModel.shouldRetryStatementByStatement(syntaxError, sql: dump))
    }

    /// A genuine one-statement typo raises the same `.invalidSyntax`.
    /// Splitting can't help it, and retrying would only restate the error.
    func testSingleStatementTypoIsNotRetried() {
        XCTAssertFalse(SQLConsoleViewModel.shouldRetryStatementByStatement(
            syntaxError, sql: "SELECT * FORM `widgets`;"
        ))
    }

    /// A routine body is valid only when sent whole — the splitter would cut
    /// it at the `;`s inside `BEGIN…END`, so a real error in the body must
    /// be reported as-is rather than buried under fragment errors.
    func testRoutineBodyIsNotRetried() {
        let procedure = """
        CREATE PROCEDURE `bump`(IN n INT)
        BEGIN
          UPDATE `a` SET `id` = `id` + n;
          SELECT ROW_COUNT();
        END
        """
        XCTAssertFalse(SQLConsoleViewModel.shouldRetryStatementByStatement(syntaxError, sql: procedure))
    }

    /// `BEGIN` as a transaction keyword isn't a routine body — a script
    /// wrapping its statements in one still splits safely.
    func testTransactionBlockIsStillRetried() {
        let script = """
        BEGIN;
        INSERT INTO `a` VALUES (1);
        COMMIT;
        """
        XCTAssertTrue(SQLConsoleViewModel.shouldRetryStatementByStatement(syntaxError, sql: script))
    }

    /// An unrelated failure (a missing table, say) must not trigger a
    /// retry — the script ran as intended and simply failed.
    func testUnrelatedErrorIsNotRetried() {
        let error = MySQLError.duplicateEntry("Duplicate entry '1' for key 'PRIMARY'")
        let dump = "INSERT INTO `a` VALUES (1);\nINSERT INTO `a` VALUES (2);"
        XCTAssertFalse(SQLConsoleViewModel.shouldRetryStatementByStatement(error, sql: dump))
    }

    // MARK: - Unknown collation

    /// `SELECT VERSION()` strings, as the two servers actually format them.
    func testServerDescriptionNamesMariaDBAndMySQLApart() {
        XCTAssertEqual(SQLConsoleViewModel.describeServer("10.4.32-MariaDB"), "MariaDB 10.4.32")
        XCTAssertEqual(SQLConsoleViewModel.describeServer("11.4.2-MariaDB-log"), "MariaDB 11.4.2")
        // A MySQL build tag isn't a product name — cPanel's is the case
        // that prompted this feature.
        XCTAssertEqual(SQLConsoleViewModel.describeServer("8.0.45-cll-lve"), "MySQL 8.0.45")
        XCTAssertEqual(SQLConsoleViewModel.describeServer("8.0.36"), "MySQL 8.0.36")
    }

    /// The reported case: a MySQL 8 dump restored onto local MariaDB. The
    /// hint has to name both the collation and the server actually in use.
    func testMySQL8CollationHintNamesTheConnectedServer() throws {
        let hint = try XCTUnwrap(SQLConsoleViewModel.unknownCollationHint(
            errorMessage: "Unknown collation: 'utf8mb4_0900_ai_ci'",
            serverVersion: "10.4.32-MariaDB"
        ))
        XCTAssertTrue(hint.contains("utf8mb4_0900_ai_ci"))
        XCTAssertTrue(hint.contains("MariaDB 10.4.32"))
        XCTAssertTrue(hint.contains("utf8mb4_unicode_ci"), "yerine ne konacağı söylenmeli")
    }

    /// The version probe is best-effort, so the hint still has to work
    /// without it — just without naming the server.
    func testMySQL8CollationHintWorksWithoutAKnownServerVersion() throws {
        let hint = try XCTUnwrap(SQLConsoleViewModel.unknownCollationHint(
            errorMessage: "Unknown collation: 'utf8mb4_0900_as_cs'",
            serverVersion: nil
        ))
        XCTAssertTrue(hint.contains("utf8mb4_0900_as_cs"))
        XCTAssertFalse(hint.contains("MariaDB"))
    }

    /// The reverse direction — a MariaDB-only collation on MySQL — isn't a
    /// "MySQL 8.0" problem, so it gets the generic wording instead.
    func testNonMySQL8CollationGetsTheGenericWording() throws {
        let hint = try XCTUnwrap(SQLConsoleViewModel.unknownCollationHint(
            errorMessage: "Unknown collation: 'utf8mb4_uca1400_ai_ci'",
            serverVersion: "8.0.36"
        ))
        XCTAssertTrue(hint.contains("utf8mb4_uca1400_ai_ci"))
        XCTAssertTrue(hint.contains("MySQL 8.0.36"))
        XCTAssertFalse(hint.contains("MySQL 8.0 collation"))
    }

    /// An error that isn't about a collation must not produce a collation
    /// hint, even though it reaches the same code path.
    func testUnparseableErrorMessageProducesNoHint() {
        XCTAssertNil(SQLConsoleViewModel.unknownCollationHint(
            errorMessage: "Table 'a' already exists",
            serverVersion: "10.4.32-MariaDB"
        ))
    }
}

/// Hits the real local server (same convention as the other DB-backed
/// suites) to confirm the version probe on connect actually populates —
/// the hint above is only useful if `serverVersion` is really there.
final class MySQLServiceVersionTests: XCTestCase {
    func testConnectCapturesTheServerVersion() async throws {
        let service = MySQLService()
        try await service.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username, password: TestDatabase.password, database: "mysqlmacclient_test")
        defer { Task { try? await service.disconnect() } }

        let reported = await service.serverVersion
        let version = try XCTUnwrap(reported, "bağlanınca sürüm okunmalı")
        XCTAssertFalse(version.isEmpty)
        // Renders as one of the two products, with a version number.
        let described = await MainActor.run { SQLConsoleViewModel.describeServer(version) }
        XCTAssertTrue(described.hasPrefix("MariaDB ") || described.hasPrefix("MySQL "), described)
        print("Local server reports: \(version) -> \(described)")
    }
}
