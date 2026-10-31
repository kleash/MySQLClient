import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP), not a mock. Each test
/// starts from a freshly created `alter_scratch` table and drops it (and
/// its possible renamed variant) afterwards, so a failed run leaves no
/// debris.
@MainActor
final class AlterTableViewModelTests: XCTestCase {
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
        try await dropScratchTables()
        try await service.execute("""
            CREATE TABLE alter_scratch (
              id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
              title VARCHAR(50) NOT NULL,
              qty INT NULL DEFAULT 5
            )
            """)
    }

    override func tearDown() async throws {
        try await dropScratchTables()
        try await service.disconnect()
    }

    private func dropScratchTables() async throws {
        try await service.execute("DROP TABLE IF EXISTS alter_scratch")
        try await service.execute("DROP TABLE IF EXISTS alter_scratch_renamed")
    }

    private func makeViewModel() async -> AlterTableViewModel {
        let viewModel = AlterTableViewModel(
            service: service,
            table: TableInfo(database: "mysqlmacclient_test", name: "alter_scratch", isView: false)
        )
        await viewModel.load()
        return viewModel
    }

    func testLoadSeedsDraftsFromLiveSchema() async throws {
        let viewModel = await makeViewModel()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.columns.map(\.name), ["id", "title", "qty"])

        let id = viewModel.columns[0]
        XCTAssertEqual(id.dataType, "INT")
        XCTAssertTrue(id.isPrimaryKey)
        XCTAssertTrue(id.isAutoIncrement)
        XCTAssertTrue(id.isNotNull)

        let title = viewModel.columns[1]
        XCTAssertEqual(title.dataType, "VARCHAR")
        XCTAssertEqual(title.length, "50")
        XCTAssertTrue(title.isNotNull)

        let qty = viewModel.columns[2]
        XCTAssertEqual(qty.defaultValue, "5")
        XCTAssertFalse(qty.isNotNull)
    }

    func testNoChangesBlocksSubmit() async throws {
        let viewModel = await makeViewModel()

        XCTAssertFalse(viewModel.canSubmit)
        XCTAssertEqual(viewModel.previewSQL, AlterTableViewModel.noChangesPreview)

        let result = await viewModel.submit()
        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorMessage, CreateTableError.noChanges.errorDescription)
    }

    func testAddColumnAppliesAddClause() async throws {
        let viewModel = await makeViewModel()
        var newColumn = DraftColumn()
        newColumn.name = "note"
        newColumn.dataType = "VARCHAR"
        newColumn.length = "100"
        viewModel.columns.append(newColumn)

        XCTAssertTrue(viewModel.previewSQL.contains("ADD COLUMN `note` VARCHAR(100) NULL"))
        let result = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(result)
        let columns = try await introspection.columns(forTable: "alter_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(columns.map(\.name), ["id", "title", "qty", "note"])
    }

    func testDropColumnAppliesDropClause() async throws {
        let viewModel = await makeViewModel()
        viewModel.columns.removeAll { $0.name == "qty" }

        XCTAssertTrue(viewModel.previewSQL.contains("DROP COLUMN `qty`"))
        _ = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        let columns = try await introspection.columns(forTable: "alter_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(columns.map(\.name), ["id", "title"])
    }

    func testRenameAndResizeColumnUsesChangeClause() async throws {
        let viewModel = await makeViewModel()
        guard let index = viewModel.columns.firstIndex(where: { $0.name == "title" }) else {
            return XCTFail("title kolonu bulunamadı")
        }
        viewModel.columns[index].name = "heading"
        viewModel.columns[index].length = "80"

        XCTAssertTrue(viewModel.previewSQL.contains("CHANGE COLUMN `title` `heading` VARCHAR(80) NOT NULL"))
        _ = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        let columns = try await introspection.columns(forTable: "alter_scratch", inDatabase: "mysqlmacclient_test")
        let heading = columns.first { $0.name == "heading" }
        XCTAssertNotNil(heading)
        XCTAssertEqual(heading?.mysqlType.lowercased(), "varchar(80)")
        XCTAssertFalse(columns.contains { $0.name == "title" })
    }

    func testUnchangedColumnCommentSurvivesAnotherColumnsChange() async throws {
        try await service.execute("ALTER TABLE alter_scratch CHANGE COLUMN title title VARCHAR(50) NOT NULL COMMENT 'başlık alanı'")
        let viewModel = await makeViewModel()
        guard let index = viewModel.columns.firstIndex(where: { $0.name == "title" }) else {
            return XCTFail("title kolonu bulunamadı")
        }
        XCTAssertEqual(viewModel.columns[index].comment, "başlık alanı")

        // Change something *else* about the commented column: the emitted
        // CHANGE COLUMN must re-state the comment, or MySQL wipes it.
        viewModel.columns[index].length = "60"
        _ = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        let columns = try await introspection.columns(forTable: "alter_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(columns.first { $0.name == "title" }?.comment, "başlık alanı")
    }

    func testRenameTableAppliesRenameToAndReturnsNewInfo() async throws {
        let viewModel = await makeViewModel()
        viewModel.tableName = "alter_scratch_renamed"

        // Qualified with the database, not just `` `alter_scratch_renamed` ``:
        // this app never issues a server-side `USE`, so an unqualified
        // RENAME TO target fails with "No database selected" on a
        // connection that was never given a default database (a real
        // connection to a multi-database server, as opposed to this test's
        // `database: "mysqlmacclient_test"` connect-time default, which
        // masked the bug).
        XCTAssertTrue(viewModel.previewSQL.contains("RENAME TO `mysqlmacclient_test`.`alter_scratch_renamed`"))
        let result = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(result?.name, "alter_scratch_renamed")
        let tables = try await introspection.listTablesAndViews(inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(tables.contains { $0.name == "alter_scratch_renamed" })
        XCTAssertFalse(tables.contains { $0.name == "alter_scratch" })
    }

    func testMoveColumnEmitsPositionClauseAndAppliesNewOrder() async throws {
        let viewModel = await makeViewModel()
        // id, title, qty → id, qty, title
        viewModel.columns.swapAt(1, 2)

        XCTAssertTrue(
            viewModel.previewSQL.contains("AFTER") || viewModel.previewSQL.contains("FIRST"),
            "sıra değişikliği konum ifadesi üretmeliydi: \(viewModel.previewSQL)"
        )
        _ = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        let columns = try await introspection.columns(forTable: "alter_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(columns.map(\.name), ["id", "qty", "title"])
    }

    func testReversingAllColumnsAppliesNewOrder() async throws {
        let viewModel = await makeViewModel()
        viewModel.columns.reverse() // qty, title, id

        _ = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        let columns = try await introspection.columns(forTable: "alter_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(columns.map(\.name), ["qty", "title", "id"])
    }

    func testNewColumnInsertedInMiddleGetsPositionClause() async throws {
        let viewModel = await makeViewModel()
        var newColumn = DraftColumn()
        newColumn.name = "slug"
        newColumn.dataType = "VARCHAR"
        newColumn.length = "40"
        viewModel.columns.insert(newColumn, at: 1) // id, slug, title, qty

        XCTAssertTrue(viewModel.previewSQL.contains("ADD COLUMN `slug` VARCHAR(40) NULL AFTER `id`"))
        _ = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        let columns = try await introspection.columns(forTable: "alter_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(columns.map(\.name), ["id", "slug", "title", "qty"])
    }

    func testLongestCommonSubsequenceBasics() {
        XCTAssertEqual(
            AlterTableViewModel.longestCommonSubsequence(["a", "b", "c"], ["a", "c", "b"]).count,
            2
        )
        XCTAssertEqual(
            AlterTableViewModel.longestCommonSubsequence(["a", "b", "c"], ["a", "b", "c"]),
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            AlterTableViewModel.longestCommonSubsequence([], ["a"]),
            []
        )
    }

    func testMovingPrimaryKeyToAnotherColumnDropsAndReadds() async throws {
        let viewModel = await makeViewModel()
        guard let idIndex = viewModel.columns.firstIndex(where: { $0.name == "id" }),
              let qtyIndex = viewModel.columns.firstIndex(where: { $0.name == "qty" }) else {
            return XCTFail("beklenen kolonlar bulunamadı")
        }
        // AUTO_INCREMENT requires its column to be a key, so it has to go
        // in the same statement that drops the PK from `id`.
        viewModel.columns[idIndex].isAutoIncrement = false
        viewModel.columns[idIndex].isPrimaryKey = false
        viewModel.columns[qtyIndex].isPrimaryKey = true

        XCTAssertTrue(viewModel.previewSQL.contains("DROP PRIMARY KEY"))
        XCTAssertTrue(viewModel.previewSQL.contains("ADD PRIMARY KEY (`qty`)"))
        _ = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        let pkColumns = try await introspection.primaryKeyColumnNames(forTable: "alter_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(pkColumns, ["qty"])
    }
}
