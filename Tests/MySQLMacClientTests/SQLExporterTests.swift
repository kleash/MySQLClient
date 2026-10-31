import XCTest
@testable import MySQLMacClient

final class SQLExporterTests: XCTestCase {
    private let columns = [
        ColumnInfo(name: "id", mysqlType: "int(11)", isNullable: false, isPrimaryKey: true, isAutoIncrement: true, defaultValue: nil),
        ColumnInfo(name: "name", mysqlType: "varchar(100)", isNullable: false, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
        ColumnInfo(name: "notes", mysqlType: "varchar(255)", isNullable: true, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
    ]

    func testCreateTableStatementInsertsIfNotExistsAndTerminates() {
        let raw = "CREATE TABLE `widgets` (\n  `id` int NOT NULL\n) ENGINE=InnoDB"
        let result = SQLExporter.createTableStatement(rawShowCreateTable: raw)
        XCTAssertEqual(result, "CREATE TABLE IF NOT EXISTS `widgets` (\n  `id` int NOT NULL\n) ENGINE=InnoDB;")
    }

    func testCreateViewStatementInsertsOrReplaceAndTerminates() {
        let raw = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `widget_view` AS select `widgets`.`id` AS `id` from `widgets`"
        let result = SQLExporter.createViewStatement(rawShowCreateView: raw)
        XCTAssertEqual(
            result,
            "CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `widget_view` AS select `widgets`.`id` AS `id` from `widgets`;"
        )
    }

    func testInsertStatementWithMixedTypes() {
        let sql = SQLExporter.insertStatement(database: "testdb", table: "widgets", columns: columns, values: [.int(1), .string("Bolt"), .null])
        XCTAssertEqual(sql, "INSERT INTO `testdb`.`widgets` (`id`, `name`, `notes`) VALUES (1, 'Bolt', NULL);")
    }

    func testStringLiteralEscaping() {
        XCTAssertEqual(SQLExporter.escapeStringLiteral("O'Brien"), "O''Brien")
        XCTAssertEqual(SQLExporter.escapeStringLiteral("C:\\path"), "C:\\\\path")
        XCTAssertEqual(SQLExporter.escapeStringLiteral("a\0b\u{1A}c\r\nd"), "a\\0b\\Zc\\r\\nd")
    }

    /// A combining mark makes one Character of itself and the character
    /// before it, so a replace that compares Characters would leave a quote,
    /// backslash or backtick followed by one unescaped.
    func testEscapingStillAppliesBeforeACombiningMark() {
        let mark = "\u{301}"
        XCTAssertEqual(SQLExporter.escapeStringLiteral("x'\(mark)y"), "x''\(mark)y")
        XCTAssertEqual(SQLExporter.escapeStringLiteral("x\\\(mark)y"), "x\\\\\(mark)y")
        XCTAssertEqual(
            SQLExporter.escapeStringLiteral("\0\(mark)\n\(mark)\r\(mark)\u{1A}\(mark)"),
            "\\0\(mark)\\n\(mark)\\r\(mark)\\Z\(mark)"
        )
        XCTAssertEqual(SQLExporter.quoted("a`\(mark)b"), "`a``\(mark)b`")
    }

    func testBlobRendersAsHexLiteral() {
        let sql = SQLExporter.insertStatement(database: "db", table: "t", columns: [columns[0]], values: [.blob(Data([0x00, 0xFF]))])
        XCTAssertEqual(sql, "INSERT INTO `db`.`t` (`id`) VALUES (X'00ff');")
    }

    func testEmptyBlobRendersAsEmptyHexLiteral() {
        XCTAssertEqual(SQLExporter.hexLiteral(Data()), "X''")
    }

    func testHexLiteralWritesEveryByteAsTwoDigits() {
        let expected = "X'" + (0...255).map { String(format: "%02x", $0) }.joined() + "'"
        XCTAssertEqual(SQLExporter.hexLiteral(Data(0...255)), expected)
    }

    func testWriteEmitsCreateTableFollowedByOneInsertPerRow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sql")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)

        try SQLExporter.write(
            database: "testdb",
            table: "widgets",
            createTableSQL: "CREATE TABLE IF NOT EXISTS `widgets` (`id` int);",
            columns: [columns[0]],
            rows: [[.int(1)], [.int(2)]],
            to: handle
        )
        try handle.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("CREATE TABLE IF NOT EXISTS `widgets` (`id` int);"))
        XCTAssertTrue(contents.contains("INSERT INTO `testdb`.`widgets` (`id`) VALUES (1);"))
        XCTAssertTrue(contents.contains("INSERT INTO `testdb`.`widgets` (`id`) VALUES (2);"))
    }

    /// A write that fails, as on a full disk (here the handle is open only
    /// for reading), has to throw so the caller can clean up and say so.
    /// `FileHandle.write(_:)` raises an Objective-C exception instead, which
    /// nothing catches.
    func testWriteThrowsWhenTheFileCannotBeWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sql")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        XCTAssertThrowsError(try SQLExporter.write(
            database: "testdb", table: "widgets", createTableSQL: "", columns: [columns[0]], rows: [[.int(1)]], to: handle
        ))
    }

    // MARK: - Database Backup

    func testDropTableStatementEmitsDropIfExists() {
        XCTAssertEqual(SQLExporter.dropTableStatement(table: "widgets"), "DROP TABLE IF EXISTS `widgets`;")
    }

    func testDropViewStatementEmitsDropIfExists() {
        XCTAssertEqual(SQLExporter.dropViewStatement(view: "widget_view"), "DROP VIEW IF EXISTS `widget_view`;")
    }

    func testDropRoutineStatementUsesTheRoutinesSQLKeyword() {
        let procedure = RoutineInfo(database: "testdb", name: "doStuff", kind: .procedure)
        XCTAssertEqual(SQLExporter.dropRoutineStatement(procedure), "DROP PROCEDURE IF EXISTS `doStuff`;")

        let function = RoutineInfo(database: "testdb", name: "computeStuff", kind: .function)
        XCTAssertEqual(SQLExporter.dropRoutineStatement(function), "DROP FUNCTION IF EXISTS `computeStuff`;")
    }

    func testDelimiterWrappedRoutineStatementWrapsBodyInDelimiterDollarDollar() {
        let raw = "CREATE PROCEDURE `testdb`.`doStuff`()\nBEGIN\n  SELECT 1;\nEND"
        let result = SQLExporter.delimiterWrappedRoutineStatement(rawShowCreateRoutine: raw)
        XCTAssertEqual(result, "DELIMITER $$\n\nCREATE PROCEDURE `testdb`.`doStuff`()\nBEGIN\n  SELECT 1;\nEND$$\n\nDELIMITER ;")
    }

    func testInsertStatementsProducesOneStatementWhenUnderBothCaps() {
        let rows = [["1", "'Bolt'"], ["2", "'Nut'"], ["3", "'Washer'"]]
        let statements = SQLExporter.insertStatements(into: "`widgets`", columnNames: ["id", "name"], literalRows: rows)
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(
            statements.first,
            "INSERT INTO `widgets` (`id`, `name`) VALUES (1, 'Bolt'), (2, 'Nut'), (3, 'Washer');"
        )
    }

    func testInsertStatementsSplitsWhenRowCountCapExceeded() {
        let rows = (1...5).map { [String($0)] }
        let statements = SQLExporter.insertStatements(
            into: "`widgets`", columnNames: ["id"], literalRows: rows,
            maxRowsPerStatement: 2
        )
        XCTAssertEqual(statements.count, 3)
        XCTAssertEqual(statements[0], "INSERT INTO `widgets` (`id`) VALUES (1), (2);")
        XCTAssertEqual(statements[1], "INSERT INTO `widgets` (`id`) VALUES (3), (4);")
        XCTAssertEqual(statements[2], "INSERT INTO `widgets` (`id`) VALUES (5);")
    }

    func testInsertStatementsSplitsWhenByteBudgetExceeded() {
        // Each tuple "(1)" etc. is 3 bytes; a budget far smaller than two
        // tuples plus the "INSERT INTO ... VALUES " prefix forces a split
        // after every single row even though the row cap is never hit.
        let rows = (1...3).map { [String($0)] }
        let prefixLength = "INSERT INTO `widgets` (`id`) VALUES ".utf8.count
        let statements = SQLExporter.insertStatements(
            into: "`widgets`", columnNames: ["id"], literalRows: rows,
            maxStatementByteBudget: prefixLength + 3
        )
        XCTAssertEqual(statements.count, 3)
        XCTAssertEqual(statements[0], "INSERT INTO `widgets` (`id`) VALUES (1);")
        XCTAssertEqual(statements[1], "INSERT INTO `widgets` (`id`) VALUES (2);")
        XCTAssertEqual(statements[2], "INSERT INTO `widgets` (`id`) VALUES (3);")
    }

    /// A single row whose own tuple already exceeds the byte budget must
    /// still be emitted alone — never dropped, never looped on forever.
    func testInsertStatementsAlwaysEmitsASingleOversizedRowAlone() {
        let longName = String(repeating: "x", count: 1000)
        let rows = [["1", "'\(longName)'"]]
        let statements = SQLExporter.insertStatements(
            into: "`widgets`", columnNames: ["id", "name"], literalRows: rows,
            maxStatementByteBudget: 10
        )
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].contains(longName))
    }

    func testInsertStatementsWithNoRowsReturnsEmptyArray() {
        XCTAssertEqual(SQLExporter.insertStatements(into: "`widgets`", columnNames: ["id"], literalRows: []), [])
    }
}
