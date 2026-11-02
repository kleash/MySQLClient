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

    /// Through an SSH server: Host and Port are then the database as that
    /// server sees it.
    @Published var usesSSH = false
    @Published var sshHost = ""
    @Published var sshPort = "22"
    @Published var sshUsername = ""
    /// Empty: the keys ssh finds by itself.
    @Published var sshKeyFile = ""
    /// The SSH server reached through an HTTP proxy.
    @Published var usesProxy = false
    @Published var proxyHost = ""
    @Published var proxyPort = "8080"
    @Published var proxyUsername = ""
    @Published var proxyPassword = ""
    /// The folder ssh keeps its config, known hosts and keys in; nil for
    /// its own (~/.ssh). In the App Sandbox ssh can't open ~/.ssh, only a
    /// folder the user chose, kept for later launches as a bookmark.
    @Published var sshFolder: URL?

    /// The release app is sandboxed; `swift run` isn't.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    private static let sshFolderDefaultsKey = "sshFolderBookmark"

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
        if Self.isSandboxed, let bookmark = UserDefaults.standard.data(forKey: Self.sshFolderDefaultsKey) {
            // shortcut: a stale bookmark isn't renewed; it still resolves
            // while the folder can be found, and is chosen again if not.
            var isStale = false
            sshFolder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
        }
    }

    /// The SSH folder the user chose in the open panel, for ssh now and
    /// after the next launch.
    func useSSHFolder(_ folder: URL) {
        // ssh is given its known_hosts there in quotes, in an option that a
        // double quote or a control character (a line break) would cut short.
        guard !folder.path.unicodeScalars.contains(where: { $0 == "\"" || $0.properties.generalCategory == .control }) else {
            errorMessage = String(localized: "ssh can't use a folder whose path has a double quote or a control character in it.")
            return
        }
        UserDefaults.standard.set(try? folder.bookmarkData(options: .withSecurityScope), forKey: Self.sshFolderDefaultsKey)
        sshFolder = folder
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
        usesSSH = profile.ssh != nil
        sshHost = profile.ssh?.host ?? ""
        sshPort = String(profile.ssh?.port ?? 22)
        sshUsername = profile.ssh?.username ?? ""
        sshKeyFile = profile.ssh?.keyFile ?? ""
        usesProxy = profile.ssh?.proxy != nil
        proxyHost = profile.ssh?.proxy?.host ?? ""
        proxyPort = String(profile.ssh?.proxy?.port ?? 8080)
        proxyUsername = profile.ssh?.proxy?.username ?? ""
        errorMessage = nil

        let storedPassword = (try? keychainService.readPassword(forConnectionId: profile.id)) ?? nil
        password = storedPassword ?? ""
        savePassword = storedPassword != nil
        proxyPassword = ((try? keychainService.readPassword(forConnectionId: profile.id, item: KeychainService.proxyPasswordItem)) ?? nil) ?? ""
    }

    var canSubmit: Bool {
        !host.isEmpty && !username.isEmpty && Int(port) != nil && !isConnecting
            && (!usesSSH || !sshHost.isEmpty && Int(sshPort) != nil)
            && (!usesSSH || !usesProxy || !proxyHost.isEmpty && Int(proxyPort) != nil)
    }

    /// The SSH settings the form describes, nil without SSH.
    private var sshSettings: SSHSettings? {
        guard usesSSH, let sshPortNumber = Int(sshPort) else { return nil }
        let proxy = usesProxy ? Int(proxyPort).map {
            HTTPProxySettings(host: proxyHost.trimmingCharacters(in: .whitespaces), port: $0,
                              username: proxyUsername.trimmingCharacters(in: .whitespaces))
        } : nil
        return SSHSettings(host: sshHost.trimmingCharacters(in: .whitespaces), port: sshPortNumber,
                           username: sshUsername.trimmingCharacters(in: .whitespaces), keyFile: sshKeyFile, proxy: proxy)
    }

    func connect() async -> AppSession? {
        errorMessage = nil
        guard let portNumber = Int(port) else {
            errorMessage = String(localized: "Port must be numeric.")
            return nil
        }
        // Without a folder to keep known_hosts in, a sandboxed ssh would
        // trust any host key it's shown, every time.
        if usesSSH, Self.isSandboxed, sshFolder == nil {
            errorMessage = String(localized: "Choose your SSH folder first: ssh can only use the keys and known hosts in a folder you choose.")
            return nil
        }

        isConnecting = true
        defer { isConnecting = false }

        // The form as it is now: by the time the tunnel is open it can show
        // another saved connection, whose fields mustn't log in or be saved
        // as this one.
        let trimmedDatabase = database.trimmingCharacters(in: .whitespaces)
        let ssh = sshSettings
        let name = name, host = host, username = username, password = password, savePassword = savePassword
        let note = note, tlsMode = tlsMode, proxyPassword = proxyPassword, profileId = editingProfileId
        let service = MySQLService()
        var tunnel: SSHTunnel?
        do {
            var connectHost = host
            var connectPort = portNumber
            if let ssh {
                let proxy = ssh.proxy.map {
                    HTTPProxyConnector.Proxy(host: $0.host, port: $0.port, username: $0.username, password: proxyPassword)
                }
                let opened = SSHTunnel(settings: ssh, proxy: proxy, sshFolder: sshFolder)
                tunnel = opened
                connectPort = try await opened.open(to: host, port: portNumber)
                connectHost = "127.0.0.1"
                await service.setTunnel(opened)
            }
            try await service.connect(
                host: connectHost,
                port: connectPort,
                username: username,
                password: password.isEmpty ? nil : password,
                database: trimmedDatabase.isEmpty ? nil : trimmedDatabase,
                tls: tlsMode,
                serverName: ssh != nil ? host : nil
            )
        } catch {
            tunnel?.close()
            errorMessage = String(localized: "Could not connect: \(error.localizedDescription)")
            return nil
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ConnectionProfile(
            id: profileId ?? UUID(),
            name: name.isEmpty ? "\(username)@\(host)" : name,
            host: host,
            port: portNumber,
            username: username,
            database: trimmedDatabase.isEmpty ? nil : trimmedDatabase,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            tlsMode: tlsMode,
            ssh: ssh
        )
        if savePassword {
            try? keychainService.savePassword(password, forConnectionId: profile.id)
        } else if profileId != nil {
            try? keychainService.deletePassword(forConnectionId: profile.id)
        }
        // The proxy's password goes with the database's: saved or not.
        if savePassword, ssh?.proxy != nil, !proxyPassword.isEmpty {
            try? keychainService.savePassword(proxyPassword, forConnectionId: profile.id, item: KeychainService.proxyPasswordItem)
        } else if profileId != nil {
            try? keychainService.deletePassword(forConnectionId: profile.id, item: KeychainService.proxyPasswordItem)
        }
        if profileId != nil {
            connectionStore.update(profile)
        } else {
            connectionStore.add(profile)
        }
        // Unless the form has moved on to another connection meanwhile.
        if editingProfileId == profileId { editingProfileId = profile.id }

        return AppSession(
            profile: profile,
            mysqlService: service,
            introspectionService: SchemaIntrospectionService(service: service),
            tunnel: tunnel
        )
    }

    /// Removes a saved connection from the sidebar and its Keychain entry
    /// (if any was ever stored — safe to call even when the password was
    /// never saved).
    func delete(_ profile: ConnectionProfile) {
        connectionStore.remove(profile)
        try? keychainService.deletePassword(forConnectionId: profile.id)
        try? keychainService.deletePassword(forConnectionId: profile.id, item: KeychainService.proxyPasswordItem)
        // The form keeps its fields, as a new connection: Connect mustn't
        // save them under the deleted one's id.
        if editingProfileId == profile.id { editingProfileId = nil }
    }
}
