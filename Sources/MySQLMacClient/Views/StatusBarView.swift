import SwiftUI

struct StatusBarView: View {
    let profile: ConnectionProfile
    /// The currently selected table's total row count — `nil` when nothing
    /// is selected (or it hasn't loaded yet), in which case nothing is
    /// shown rather than a misleading "0 Satır".
    let rowCount: Int?
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            Text("\(profile.username)@\(profile.host):\(profile.port)\(profile.database.map { "/\($0)" } ?? "")")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            // Through SSH, Host is the database as the SSH server sees it,
            // often 127.0.0.1: alone it would read like a local one.
            if let ssh = profile.ssh {
                Text("via \(ssh.host)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            if let rowCount {
                Text("•")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                Text("\(rowCount) rows")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()
            Button("Disconnect", action: onDisconnect)
                .font(.system(size: 14))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
