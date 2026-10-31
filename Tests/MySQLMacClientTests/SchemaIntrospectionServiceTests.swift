import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP), not a mock — see
/// MySQLClient.md's validation plan. Requires the `mysqlmacclient_test`
/// schema (widgets + widget_logs_nopk + widget_view) to exist on the
/// `TestDatabase` server (`testenv/fixtures.sql` creates it).
final class SchemaIntrospectionServiceTests: XCTestCase {
    var service: MySQLService!
    var introspection: SchemaIntrospectionService!

    override func setUp() async throws {
        service = MySQLService()
        try await service.connect(
            host: TestDatabase.host,
            port: TestDatabase.port,
            username: TestDatabase.username,
            password: TestDatabase.password,
            database: "mysqlmacclient_test"
        )
        introspection = SchemaIntrospectionService(service: service)
    }

    override func tearDown() async throws {
        try await service.disconnect()
    }

    func testListDatabasesIncludesTestSchema() async throws {
        let databases = try await introspection.listDatabases()
        XCTAssertTrue(databases.map(\.name).contains("mysqlmacclient_test"))
    }

    func testListTablesAndViewsDistinguishesViewsFromBaseTables() async throws {
        let entries = try await introspection.listTablesAndViews(inDatabase: "mysqlmacclient_test")
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        XCTAssertEqual(byName["widgets"]?.isView, false)
        XCTAssertEqual(byName["widget_logs_nopk"]?.isView, false)
        XCTAssertEqual(byName["widget_view"]?.isView, true)
    }

    func testColumnsDetectsPrimaryKeyAutoIncrementAndNullability() async throws {
        let columns = try await introspection.columns(forTable: "widgets", inDatabase: "mysqlmacclient_test")
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })

        XCTAssertEqual(byName["id"]?.isPrimaryKey, true)
        XCTAssertEqual(byName["id"]?.isAutoIncrement, true)
        XCTAssertEqual(byName["name"]?.isNullable, false)
        XCTAssertEqual(byName["quantity"]?.isNullable, true)
        XCTAssertEqual(byName["notes"]?.isPrimaryKey, false)
    }

    func testColumnsOnTableWithoutPrimaryKey() async throws {
        let columns = try await introspection.columns(forTable: "widget_logs_nopk", inDatabase: "mysqlmacclient_test")
        XCTAssertFalse(columns.isEmpty)
        XCTAssertTrue(columns.allSatisfy { !$0.isPrimaryKey })
    }

    func testPrimaryKeyColumnNames() async throws {
        let pk = try await introspection.primaryKeyColumnNames(forTable: "widgets", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(pk, ["id"])

        let noPK = try await introspection.primaryKeyColumnNames(forTable: "widget_logs_nopk", inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(noPK.isEmpty)
    }

    func testIndexesGroupsColumnsByKeyNameInSequenceOrder() async throws {
        let indexes = try await introspection.indexes(forTable: "widgets", inDatabase: "mysqlmacclient_test")
        let byName = Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) })

        XCTAssertEqual(byName["PRIMARY"]?.columns, ["id"])
        XCTAssertEqual(byName["PRIMARY"]?.isUnique, true)
        XCTAssertEqual(byName["idx_name_quantity"]?.columns, ["name", "quantity"])
        XCTAssertEqual(byName["idx_name_quantity"]?.isUnique, false)
    }

    /// The qualified query (`` SHOW CREATE VIEW `db`.`view` ``) is what
    /// actually runs — MySQL then fully qualifies every reference in the
    /// response with that same `` `db`. `` prefix, which `showCreateView`
    /// must strip back out so "Alter View" produces the same unqualified
    /// style a plain `USE db; SHOW CREATE VIEW view` would have.
    func testShowCreateViewStripsSchemaQualifiers() async throws {
        let createView = try await introspection.showCreateView("widget_view", inDatabase: "mysqlmacclient_test")

        XCTAssertFalse(createView.contains("`mysqlmacclient_test`."))
        XCTAssertTrue(createView.contains("VIEW `widget_view` AS"))
        XCTAssertTrue(createView.contains("from `widgets`"))
    }

    func testShowCreateTableReturnsCreateTableStatement() async throws {
        let createTable = try await introspection.showCreateTable("widgets", inDatabase: "mysqlmacclient_test")

        XCTAssertTrue(createTable.contains("CREATE TABLE `widgets`"))
        XCTAssertTrue(createTable.contains("`id`"))
        XCTAssertTrue(createTable.contains("PRIMARY KEY"))
    }

    func testListRoutinesReturnsCreatedProcedure() async throws {
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS introspection_test_proc")
        _ = try await service.rawQuery("""
            CREATE PROCEDURE introspection_test_proc()
            BEGIN
                SELECT 1;
            END
            """)

        let procedures = try await introspection.listRoutines(.procedure, inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(procedures.contains { $0.name == "introspection_test_proc" && $0.database == "mysqlmacclient_test" })
        XCTAssertTrue(procedures.allSatisfy { $0.kind == .procedure })

        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS introspection_test_proc")
    }

    /// `SHOW FUNCTION STATUS` is a different statement from `SHOW PROCEDURE
    /// STATUS`, and each must only list its own kind — a function must not
    /// show up under Procedure'lar or vice versa.
    func testListRoutinesSeparatesFunctionsFromProcedures() async throws {
        _ = try await service.rawQuery("DROP FUNCTION IF EXISTS introspection_test_fn")
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS introspection_test_proc")
        _ = try await service.rawQuery("""
            CREATE FUNCTION introspection_test_fn(p INT) RETURNS INT READS SQL DATA
            BEGIN
                RETURN p * 2;
            END
            """)
        _ = try await service.rawQuery("""
            CREATE PROCEDURE introspection_test_proc()
            BEGIN
                SELECT 1;
            END
            """)

        let functions = try await introspection.listRoutines(.function, inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(functions.contains { $0.name == "introspection_test_fn" && $0.kind == .function })
        XCTAssertFalse(functions.contains { $0.name == "introspection_test_proc" })

        let procedures = try await introspection.listRoutines(.procedure, inDatabase: "mysqlmacclient_test")
        XCTAssertFalse(procedures.contains { $0.name == "introspection_test_fn" })

        _ = try await service.rawQuery("DROP FUNCTION IF EXISTS introspection_test_fn")
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS introspection_test_proc")
    }

    /// Unlike `showCreateView`, no schema-qualifier stripping is expected
    /// here — `SHOW CREATE PROCEDURE` never adds one regardless of whether
    /// the query itself used a qualified or unqualified name (verified
    /// against a real server).
    func testShowCreateRoutineReturnsVerbatimProcedureDefinition() async throws {
        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS introspection_test_proc")
        _ = try await service.rawQuery("""
            CREATE PROCEDURE introspection_test_proc(IN newQuantity INT)
            BEGIN
                UPDATE widgets SET quantity = newQuantity WHERE name = 'Bolt';
            END
            """)

        let createProcedure = try await introspection.showCreateRoutine(
            RoutineInfo(database: "mysqlmacclient_test", name: "introspection_test_proc", kind: .procedure)
        )

        XCTAssertFalse(createProcedure.contains("`mysqlmacclient_test`."))
        XCTAssertTrue(createProcedure.contains("PROCEDURE `introspection_test_proc`(IN newQuantity INT)"))
        XCTAssertTrue(createProcedure.contains("UPDATE widgets SET quantity = newQuantity WHERE name = 'Bolt';"))

        _ = try await service.rawQuery("DROP PROCEDURE IF EXISTS introspection_test_proc")
    }

    /// A function's definition comes back in a differently-named column
    /// (`Create Function`, not `Create Procedure`) — reading the wrong one
    /// silently yields nil and would surface as "tanım alınamadı".
    func testShowCreateRoutineReadsTheFunctionColumn() async throws {
        _ = try await service.rawQuery("DROP FUNCTION IF EXISTS introspection_test_fn")
        _ = try await service.rawQuery("""
            CREATE FUNCTION introspection_test_fn(p INT) RETURNS INT READS SQL DATA
            BEGIN
                RETURN p * 2;
            END
            """)

        let createFunction = try await introspection.showCreateRoutine(
            RoutineInfo(database: "mysqlmacclient_test", name: "introspection_test_fn", kind: .function)
        )

        XCTAssertTrue(createFunction.contains("FUNCTION `introspection_test_fn`(p INT)"))
        XCTAssertTrue(createFunction.contains("RETURN p * 2;"))

        _ = try await service.rawQuery("DROP FUNCTION IF EXISTS introspection_test_fn")
    }

    func testListTriggersReturnsCreatedTrigger() async throws {
        _ = try await service.rawQuery("DROP TRIGGER IF EXISTS introspection_test_trigger")
        _ = try await service.rawQuery("""
            CREATE TRIGGER introspection_test_trigger BEFORE INSERT ON widgets
            FOR EACH ROW
            BEGIN
                SET NEW.name = NEW.name;
            END
            """)

        let triggers = try await introspection.listTriggers(inDatabase: "mysqlmacclient_test")
        let trigger = triggers.first { $0.name == "introspection_test_trigger" }
        XCTAssertEqual(trigger?.table, "widgets")
        XCTAssertEqual(trigger?.timing, "BEFORE")
        XCTAssertEqual(trigger?.event, "INSERT")

        _ = try await service.rawQuery("DROP TRIGGER IF EXISTS introspection_test_trigger")
    }

    /// Same verbatim-storage/no-qualifier-stripping expectation as
    /// `testShowCreateRoutineReturnsVerbatimProcedureDefinition`, but reading
    /// the trigger-specific `SQL Original Statement` column.
    func testShowCreateTriggerReturnsVerbatimDefinition() async throws {
        _ = try await service.rawQuery("DROP TRIGGER IF EXISTS introspection_test_trigger")
        _ = try await service.rawQuery("""
            CREATE TRIGGER introspection_test_trigger BEFORE INSERT ON widgets
            FOR EACH ROW
            BEGIN
                SET NEW.name = NEW.name;
            END
            """)

        let createTrigger = try await introspection.showCreateTrigger(
            TriggerInfo(database: "mysqlmacclient_test", name: "introspection_test_trigger", table: "widgets", timing: "BEFORE", event: "INSERT")
        )

        // MariaDB's `SQL Original Statement` doesn't backtick-quote the
        // trigger/table names the way `SHOW CREATE TABLE`/`VIEW` do —
        // verified against the real local server.
        XCTAssertTrue(createTrigger.contains("TRIGGER introspection_test_trigger"))
        XCTAssertTrue(createTrigger.contains("BEFORE INSERT ON widgets"))

        _ = try await service.rawQuery("DROP TRIGGER IF EXISTS introspection_test_trigger")
    }

    /// `DISABLE` keeps the scheduler from ever actually running this —
    /// the test only needs the row to exist and report its status.
    func testListEventsReturnsCreatedEvent() async throws {
        _ = try await service.rawQuery("DROP EVENT IF EXISTS introspection_test_event")
        _ = try await service.rawQuery("""
            CREATE EVENT introspection_test_event
            ON SCHEDULE EVERY 1 DAY
            DISABLE
            DO
            BEGIN
                SELECT 1;
            END
            """)

        let events = try await introspection.listEvents(inDatabase: "mysqlmacclient_test")
        let event = events.first { $0.name == "introspection_test_event" }
        XCTAssertEqual(event?.status, "DISABLED")

        _ = try await service.rawQuery("DROP EVENT IF EXISTS introspection_test_event")
    }

    func testShowCreateEventReturnsVerbatimDefinition() async throws {
        _ = try await service.rawQuery("DROP EVENT IF EXISTS introspection_test_event")
        _ = try await service.rawQuery("""
            CREATE EVENT introspection_test_event
            ON SCHEDULE EVERY 1 DAY
            DISABLE
            DO
            BEGIN
                SELECT 1;
            END
            """)

        let createEvent = try await introspection.showCreateEvent(
            EventInfo(database: "mysqlmacclient_test", name: "introspection_test_event", status: "DISABLED")
        )

        XCTAssertTrue(createEvent.contains("EVENT `introspection_test_event`"))

        _ = try await service.rawQuery("DROP EVENT IF EXISTS introspection_test_event")
    }

    func testQuotedIdentifierRejectsBacktick() {
        XCTAssertThrowsError(try SchemaIntrospectionService.quotedIdentifier("evil`table"))
    }
}
