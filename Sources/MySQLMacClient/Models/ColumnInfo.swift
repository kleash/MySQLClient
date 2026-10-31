import Foundation

struct ColumnInfo: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let mysqlType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let isAutoIncrement: Bool
    let defaultValue: String?
    /// Column comment (from `SHOW FULL COLUMNS`). Defaulted so the many
    /// existing call sites that don't care about comments keep compiling.
    var comment: String? = nil
    /// A generated (computed) column, whose value the server works out
    /// itself and which an INSERT must not name.
    var isGenerated = false

    /// `TEXT`/`BLOB`-family columns, which the grid shows as a `<N bytes>`
    /// placeholder and edits in the value editor instead of inline.
    ///
    /// Driven by the declared type rather than by the value, so an empty or
    /// `NULL` cell in a `TEXT` column behaves like every other cell in it —
    /// a value-driven test would leave exactly those cells inline-editable
    /// and inconsistent with their neighbours.
    var isLargeObject: Bool {
        let base = mysqlType
            .lowercased()
            .prefix { $0 != "(" && $0 != " " }
        return Self.largeObjectTypes.contains(String(base))
    }

    private static let largeObjectTypes: Set<String> = [
        "tinytext", "text", "mediumtext", "longtext",
        "tinyblob", "blob", "mediumblob", "longblob",
    ]
}
