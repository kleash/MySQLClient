import Foundation

/// The 3-way "SQL OLARAK AKTAR" mode selector in the DB Backup dialog.
enum DatabaseBackupMode: String, CaseIterable, Identifiable {
    case structureOnly, dataOnly, structureAndData

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .structureOnly: return String(localized: "Structure only")
        case .dataOnly: return String(localized: "Data only")
        case .structureAndData: return String(localized: "Structure + data")
        }
    }
}

/// "KAYNAĞI ETKİLEYEN SEÇENEKLER" — how the live source database is read
/// during the dump. A single transaction by default: without it, a backup
/// of a database in use reads each table at a different moment and can
/// hold rows that never existed together (an order without its items).
/// It doesn't block writers the way `lockTablesForReading` does, but it
/// covers InnoDB tables only: another engine's (Aria, MyISAM) are read as
/// they are at each read, which only `lockTablesForReading` prevents.
///
/// Deliberately just these two: a third checkbox in the reference image
/// ("Dump öncesi logları temizle") mapped to `RESET MASTER` in real MySQL —
/// a replication-affecting, elevated-privilege operation with no safe
/// equivalent worth exposing here, so it was dropped rather than
/// reinterpreted into something that silently doesn't do what its label
/// promises.
struct DatabaseBackupSourceOptions: Equatable {
    var lockTablesForReading = false
    var useSingleTransaction = true
}

/// "DOSYAYA YAZILAN SEÇENEKLER" — what ends up written into the generated
/// `.sql` file. Defaults match the reference dialog's checked/unchecked
/// state.
struct DatabaseBackupFileOptions: Equatable {
    var includeUseStatement = true
    var includeCreateDatabaseStatement = true
    /// Also emits the matching `SET FOREIGN_KEY_CHECKS=1;` at the end of
    /// the file — the reference dialog only shows one checkbox for this,
    /// but leaving the session with checks disabled after the dump file
    /// finishes replaying would be a real, easy-to-miss footgun.
    var setForeignKeyChecksToZero = true
    var lockInsertStatements = false
    var useExtendedInserts = true
    var includeDropStatements = false
}

struct DatabaseBackupOptions: Equatable {
    var mode: DatabaseBackupMode = .structureAndData
    var source = DatabaseBackupSourceOptions()
    var file = DatabaseBackupFileOptions()
}
