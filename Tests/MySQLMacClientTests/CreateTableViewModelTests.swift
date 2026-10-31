import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP), not a mock. Every test
/// drops its scratch table in tearDown so a failed run doesn't leave debris
/// for the next one.
@MainActor
final class CreateTableViewModelTests: XCTestCase {
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
        try await service.execute("DROP TABLE IF EXISTS create_table_scratch")
    }

    override func tearDown() async throws {
        try await service.execute("DROP TABLE IF EXISTS create_table_scratch")
        try await service.disconnect()
    }

    private func makeViewModel() -> CreateTableViewModel {
        CreateTableViewModel(service: service, defaultDatabase: "mysqlmacclient_test")
    }

    func testCreatesTableWithPrimaryKeyAutoIncrementAndTypedColumns() async throws {
        let viewModel = makeViewModel()
        viewModel.tableName = "create_table_scratch"
        viewModel.columns[0].name = "id"
        viewModel.columns[0].dataType = "INT"
        viewModel.columns[0].isPrimaryKey = true
        viewModel.columns[0].isAutoIncrement = true
        viewModel.columns[1].name = "label"
        viewModel.columns[1].dataType = "VARCHAR"
        viewModel.columns[1].length = "80"
        viewModel.columns[1].isNotNull = true
        viewModel.columns[2].name = "quantity"
        viewModel.columns[2].dataType = "INT"
        viewModel.columns[2].isUnsigned = true
        viewModel.columns[2].defaultValue = "0"

        let created = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(created?.database, "mysqlmacclient_test")
        XCTAssertEqual(created?.name, "create_table_scratch")

        let columns = try await introspection.columns(forTable: "create_table_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(columns.map(\.name).sorted(), ["id", "label", "quantity"])

        let idColumn = columns.first { $0.name == "id" }
        XCTAssertEqual(idColumn?.isPrimaryKey, true)
        XCTAssertEqual(idColumn?.isAutoIncrement, true)

        let labelColumn = columns.first { $0.name == "label" }
        XCTAssertEqual(labelColumn?.mysqlType, "varchar(80)")
        XCTAssertEqual(labelColumn?.isNullable, false)

        let quantityColumn = columns.first { $0.name == "quantity" }
        XCTAssertTrue(quantityColumn?.mysqlType.contains("unsigned") ?? false)
    }

    func testEmptyTableNameFailsWithoutHittingTheDatabase() async throws {
        let viewModel = makeViewModel()
        viewModel.columns[0].name = "id"

        let created = await viewModel.submit()

        XCTAssertNil(created)
        XCTAssertEqual(viewModel.errorMessage, CreateTableError.emptyTableName.errorDescription)
    }

    func testNoNamedColumnsFails() async throws {
        let viewModel = makeViewModel()
        viewModel.tableName = "create_table_scratch"

        let created = await viewModel.submit()

        XCTAssertNil(created)
        XCTAssertEqual(viewModel.errorMessage, CreateTableError.noColumns.errorDescription)
    }

    func testMaliciousLengthValueIsRejectedInsteadOfBeingSplicedIntoTheSQL() async throws {
        let viewModel = makeViewModel()
        viewModel.tableName = "create_table_scratch"
        viewModel.columns[0].name = "id"
        viewModel.columns[0].dataType = "VARCHAR"
        viewModel.columns[0].length = "10); DROP TABLE widgets; --"

        let created = await viewModel.submit()

        XCTAssertNil(created)
        XCTAssertEqual(
            viewModel.errorMessage,
            CreateTableError.invalidLength(column: "id", value: "10); DROP TABLE widgets; --").errorDescription
        )

        // The widgets table (used by other tests) must still exist.
        let stillThere = try await introspection.listTablesAndViews(inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(stillThere.contains { $0.name == "widgets" })
    }

    func testCheckingPrimaryKeyForcesNotNull() {
        let viewModel = makeViewModel()
        viewModel.columns[0].isNotNull = false
        viewModel.columns[0].isPrimaryKey = true

        XCTAssertTrue(viewModel.columns[0].isNotNull)
    }

    // MARK: - Import columns from file

    /// `chooseColumnImportFile()` itself needs a real `NSOpenPanel`, so —
    /// same workaround as `TableImportViewModelTests` — this sets
    /// `columnImportSourceURL` directly instead of driving the picker.
    /// Proves the whole path end to end: a real file's rows produce real
    /// `DraftColumn`s, and those actually `CREATE TABLE` correctly — not
    /// just that `ColumnTypeInference` itself works in isolation (already
    /// covered by `ColumnTypeInferenceTests`).
    func testImportColumnsFromCSVPopulatesColumnsWhichThenCreateSuccessfully() async throws {
        let csvURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: csvURL) }
        try Data("id,name,price,created\n1,Ada,19.99,2024-01-15\n2,Grace,29.50,2024-02-20\n".utf8).write(to: csvURL)

        let viewModel = makeViewModel()
        viewModel.tableName = "create_table_scratch"
        XCTAssertEqual(viewModel.columnImportFormat, .csv)
        viewModel.columnImportSourceURL = csvURL
        await viewModel.importColumns()

        XCTAssertNil(viewModel.columnImportErrorMessage)
        XCTAssertEqual(viewModel.columns.map(\.name), ["id", "name", "price", "created"])
        XCTAssertEqual(viewModel.columns.map(\.dataType), ["INT", "VARCHAR", "DECIMAL", "DATE"])

        let created = await viewModel.submit()
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(created)

        let columns = try await introspection.columns(forTable: "create_table_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(columns.map(\.name).sorted(), ["created", "id", "name", "price"])
        // No row from the source CSV was ever written — only the structure.
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM create_table_scratch")
        XCTAssertEqual(rows.first?.column("cnt")?.int, 0)
    }

    func testImportColumnsFromXLSXUsesTheSelectedSheet() async throws {
        let xlsxURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: xlsxURL) }
        let columns = [ColumnInfo(name: "sku", mysqlType: "text", isNullable: true, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil)]
        try XLSXExporter.write(columns: columns, rows: [[.string("ABC123")]], includeHeaderRow: true, to: xlsxURL)

        let viewModel = makeViewModel()
        viewModel.columnImportFormat = .xlsx
        viewModel.columnImportSourceURL = xlsxURL
        await viewModel.importColumns()

        XCTAssertNil(viewModel.columnImportErrorMessage)
        XCTAssertEqual(viewModel.columns.map(\.name), ["sku"])
        XCTAssertEqual(viewModel.columns.map(\.dataType), ["VARCHAR"])
    }

    func testSwitchingColumnImportFormatClearsThePreviouslyChosenFile() async throws {
        let csvURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: csvURL) }
        try Data("id\n1\n".utf8).write(to: csvURL)

        let viewModel = makeViewModel()
        viewModel.columnImportSourceURL = csvURL
        XCTAssertNotNil(viewModel.columnImportSourceURL)

        viewModel.columnImportFormat = .xlsx

        XCTAssertNil(viewModel.columnImportSourceURL, "format değişince önceki dosya geçersiz kalır, temizlenmeli")
    }
}
