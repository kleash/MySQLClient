import Foundation

struct ConnectionProfile: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    /// nil/empty means "no default database" — the sidebar then shows every
    /// database the user can see on the server (`SHOW DATABASES`).
    var database: String?
    var note: String?
    /// `nil`: not encrypted. Optional so connections saved before this
    /// existed still load.
    var tlsMode: TLSMode?
    /// Set when the database is reached through an SSH server; `host` and
    /// `port` are then the database as that server sees it.
    var ssh: SSHSettings?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 3306,
        username: String,
        database: String?,
        note: String? = nil,
        tlsMode: TLSMode? = nil,
        ssh: SSHSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.database = database
        self.note = note
        self.tlsMode = tlsMode
        self.ssh = ssh
    }
}

/// The SSH server a connection goes through (`SSHTunnel`). Its proxy's
/// password is kept in the Keychain, like the database password.
struct SSHSettings: Codable, Equatable, Hashable {
    var host: String
    var port: Int = 22
    var username: String
    /// Empty: the keys ssh finds by itself (ssh-agent, the SSH folder).
    var keyFile: String = ""
    var proxy: HTTPProxySettings?
}

/// An HTTP proxy in front of the SSH server.
struct HTTPProxySettings: Codable, Equatable, Hashable {
    var host: String
    var port: Int
    /// Empty: the proxy wants no login.
    var username: String = ""
}

/// How the connection to the server is encrypted.
enum TLSMode: String, Codable, CaseIterable, Identifiable {
    /// Encrypted, without checking the server's certificate: works with the
    /// self-signed certificates MySQL and MariaDB generate for themselves,
    /// but doesn't prove who is answering.
    case required
    /// Encrypted, with a certificate valid for the host name and signed by
    /// an authority this Mac trusts.
    case verifyCertificate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .required: return String(localized: "Encrypt (don't verify the certificate)")
        case .verifyCertificate: return String(localized: "Encrypt and verify the certificate")
        }
    }
}
