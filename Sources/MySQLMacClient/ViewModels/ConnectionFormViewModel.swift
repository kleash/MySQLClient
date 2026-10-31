import Foundation

@MainActor
final class ConnectionFormViewModel: ObservableObject {
    @Published var name: String = ""
    @Published var host: String = "127.0.0.1"
    @Published var port: String = "3306"
    @Published var username: String = "root"
    @Published var password: String = ""
    @Published var savePassword: Bool = true
    @Published var database: String = ""
    @Published var note: String = ""
    @Published var tlsMode: TLSMode?

    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?

    /// Set by `loadForEditing`, when the form is showing a saved connection
    /// rather than a blank one. `connect()` uses this to update that profile
    /// in place instead of adding a new sidebar entry for every reconnect.
    @Published private(set) var editingProfileId: UUID?

    private let connectionStore: ConnectionStore
    private let keychainService = KeychainService()

    init(connectionStore: ConnectionStore) {
        self.connectionStore = connectionStore
    }

    /// Populates the form from a saved connection (selected in the sidebar)
    /// without connecting — the user reviews/edits the fields and connects
    /// via the "Bağlan" button. The password field is pre-filled only if one
    /// was previously saved to the Keychain.
    func loadForEditing(_ profile: ConnectionProfile) {
        editingProfileId = profile.id
        name = profile.name
        host = profile.host
        port = String(profile.port)
        username = profile.username
        database = profile.database ?? ""
        note = profile.note ?? ""
        tlsMode = profile.tlsMode
        errorMessage = nil

        let storedPassword = (try? keychainService.readPassword(forConnectionId: profile.id)) ?? nil
        password = storedPassword ?? ""
        savePassword = storedPassword != nil
    }

    var canSubmit: Bool {
        !host.isEmpty && !username.isEmpty && Int(port) != nil && !isConnecting
    }

    func connect() async -> AppSession? {
        errorMessage = nil
        guard let portNumber = Int(port) else {
            errorMessage = String(localized: "Port must be numeric.")
            return nil
        }

        isConnecting = true
        defer { isConnecting = false }

        let trimmedDatabase = database.trimmingCharacters(in: .whitespaces)
        let service = MySQLService()
        do {
            try await service.connect(
                host: host,
                port: portNumber,
                username: username,
                password: password.isEmpty ? nil : password,
                database: trimmedDatabase.isEmpty ? nil : trimmedDatabase,
                tls: tlsMode
            )
        } catch {
            errorMessage = String(localized: "Could not connect: \(error.localizedDescription)")
            return nil
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ConnectionProfile(
            id: editingProfileId ?? UUID(),
            name: name.isEmpty ? "\(username)@\(host)" : name,
            host: host,
            port: portNumber,
            username: username,
            database: trimmedDatabase.isEmpty ? nil : trimmedDatabase,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            tlsMode: tlsMode
        )
        if savePassword {
            try? keychainService.savePassword(password, forConnectionId: profile.id)
        } else if editingProfileId != nil {
            try? keychainService.deletePassword(forConnectionId: profile.id)
        }
        if editingProfileId != nil {
            connectionStore.update(profile)
        } else {
            connectionStore.add(profile)
        }
        editingProfileId = profile.id

        return AppSession(
            profile: profile,
            mysqlService: service,
            introspectionService: SchemaIntrospectionService(service: service)
        )
    }

    /// Removes a saved connection from the sidebar and its Keychain entry
    /// (if any was ever stored — safe to call even when the password was
    /// never saved).
    func delete(_ profile: ConnectionProfile) {
        connectionStore.remove(profile)
        try? keychainService.deletePassword(forConnectionId: profile.id)
    }
}
