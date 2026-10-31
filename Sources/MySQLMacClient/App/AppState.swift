import Foundation

/// A live, connected session: the profile plus the service instances bound
/// to that one connection. Created on successful connect, torn down on
/// disconnect.
struct AppSession: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let mysqlService: MySQLService
    let introspectionService: SchemaIntrospectionService
    /// Set when the connection goes through an SSH server.
    var tunnel: SSHTunnel?
}

@MainActor
final class AppState: ObservableObject {
    @Published var activeSession: AppSession?

    func disconnect() async {
        guard let session = activeSession else { return }
        activeSession = nil
        try? await session.mysqlService.disconnect()
        session.tunnel?.close()
    }
}
