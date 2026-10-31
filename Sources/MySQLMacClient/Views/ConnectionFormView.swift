import SwiftUI

struct ConnectionFormView: View {
    @ObservedObject var connectionStore: ConnectionStore
    @ObservedObject var appState: AppState
    @StateObject private var viewModel: ConnectionFormViewModel
    @State private var connectionPendingDeletion: ConnectionProfile?

    init(connectionStore: ConnectionStore, appState: AppState) {
        self.connectionStore = connectionStore
        self.appState = appState
        _viewModel = StateObject(wrappedValue: ConnectionFormViewModel(connectionStore: connectionStore))
    }

    var body: some View {
        HSplitView {
            savedConnectionsList
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)

            ScrollView { form }
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 480)
        .overlay(alignment: .topTrailing) {
            AppearancePickerView()
                .padding(12)
        }
    }

    private var savedConnectionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Saved Connections")
                .font(.headline)
                .padding(12)

            if connectionStore.connections.isEmpty {
                Text("No saved connections yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                List(connectionStore.connections) { profile in
                    savedConnectionRow(profile)
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .confirmationDialog(
            "Delete the connection '\(connectionPendingDeletion?.name ?? "")'?",
            isPresented: Binding(
                get: { connectionPendingDeletion != nil },
                set: { if !$0 { connectionPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let profile = connectionPendingDeletion {
                    viewModel.delete(profile)
                }
                connectionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                connectionPendingDeletion = nil
            }
        }
    }

    private func savedConnectionRow(_ profile: ConnectionProfile) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.loadForEditing(profile)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.body)
                    Text("\(profile.username)@\(profile.host):\(profile.port)/\(profile.database ?? "tüm veritabanları")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let note = profile.note, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                connectionPendingDeletion = profile
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete connection")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(viewModel.editingProfileId == profile.id ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New MySQL Connection")
                .font(.title2.bold())

            // Each field's on-screen name is an external label, not the
            // `TextField`'s own title — with the border's `.plain` style, a
            // `TextField`'s title renders as placeholder text *inside* the
            // box; the field's own title is reserved for a real placeholder
            // hint (shows only while the field is empty).
            //
            // A `Grid` rather than `Form`/`LabeledContent`: `Form` only
            // shares one label-column width across rows for controls it
            // recognizes natively, so with these custom bordered fields
            // every row's label was self-sized and the borders started at
            // different x positions. `Grid` sizes the label column to its
            // widest cell by construction — every border's left edge lines
            // up exactly, with no hardcoded label width to go stale.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                formRow("Connection Name") {
                    TextField("Optional", text: $viewModel.name)
                        .visibleFieldBorder()
                }
                formRow("Host") {
                    TextField("", text: $viewModel.host)
                        .visibleFieldBorder()
                }
                formRow("Port") {
                    TextField("", text: $viewModel.port)
                        .visibleFieldBorder()
                }
                formRow("Username") {
                    TextField("", text: $viewModel.username)
                        .visibleFieldBorder()
                }
                formRow("Password") {
                    HStack(spacing: 10) {
                        RevealablePasswordField(text: $viewModel.password)
                        Toggle("Save password", isOn: $viewModel.savePassword)
                            .toggleStyle(.checkbox)
                            .font(.callout)
                    }
                }
                formRow("Database") {
                    TextField("Optional — lists all if empty", text: $viewModel.database)
                        .visibleFieldBorder()
                }
                formRow("Encryption") {
                    Picker("", selection: $viewModel.tlsMode) {
                        Text("Off").tag(TLSMode?.none)
                        ForEach(TLSMode.allCases) { mode in
                            Text(mode.displayName).tag(TLSMode?.some(mode))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                formRow("SSH") {
                    Toggle("Connect through an SSH server", isOn: $viewModel.usesSSH)
                        .toggleStyle(.checkbox)
                }
                if viewModel.usesSSH {
                    formRow("SSH Host") {
                        hostAndPort(host: $viewModel.sshHost, port: $viewModel.sshPort)
                    }
                    formRow("SSH Username") {
                        TextField("", text: $viewModel.sshUsername)
                            .visibleFieldBorder()
                    }
                    if ConnectionFormViewModel.isSandboxed {
                        formRow("SSH Folder") {
                            HStack(spacing: 8) {
                                Text(viewModel.sshFolder?.path ?? String(localized: "Not chosen — ssh can only use a folder you choose"))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Choose…", action: chooseSSHFolder)
                            }
                        }
                    }
                    formRow("SSH Key") {
                        HStack(spacing: 8) {
                            TextField("Optional — ssh-agent and ~/.ssh if empty", text: $viewModel.sshKeyFile)
                                .visibleFieldBorder()
                            Button("Choose…", action: chooseKeyFile)
                        }
                    }
                    formRow("HTTP Proxy") {
                        Toggle("Reach the SSH server through an HTTP proxy", isOn: $viewModel.usesProxy)
                            .toggleStyle(.checkbox)
                    }
                    if viewModel.usesProxy {
                        formRow("Proxy Host") {
                            hostAndPort(host: $viewModel.proxyHost, port: $viewModel.proxyPort)
                        }
                        formRow("Proxy Username") {
                            TextField("Optional", text: $viewModel.proxyUsername)
                                .visibleFieldBorder()
                        }
                        formRow("Proxy Password") {
                            RevealablePasswordField(text: $viewModel.proxyPassword)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .gridLineColor)))

            VStack(alignment: .leading, spacing: 4) {
                Text("Note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.note)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 60)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .gridLineColor)))
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button {
                    Task {
                        if let session = await viewModel.connect() {
                            appState.activeSession = session
                        }
                    }
                } label: {
                    if viewModel.isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSubmit)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func hostAndPort(host: Binding<String>, port: Binding<String>) -> some View {
        HStack(spacing: 8) {
            TextField("", text: host)
                .visibleFieldBorder()
            Text("Port")
            TextField("", text: port)
                .visibleFieldBorder()
                .frame(width: 64)
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.directoryURL = viewModel.sshFolder ?? Self.homeSSHFolder
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.sshKeyFile = url.path
        }
    }

    private func chooseSSHFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = Self.homeSSHFolder
        panel.message = String(localized: "Choose the folder ssh keeps your keys and known hosts in, usually .ssh in your home folder.")
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.useSSHFolder(url)
        }
    }

    /// ~/.ssh. Not from `homeDirectoryForCurrentUser`: in the App Sandbox
    /// that's the app's container.
    private static var homeSSHFolder: URL {
        let home = getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".ssh")
    }

    /// One `Grid` row: right-aligned label in the shared label column,
    /// leading-aligned (and horizontally greedy) field in the second.
    private func formRow<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
                .lineLimit(1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A `SecureField` with an eye-icon toggle to reveal the typed password as
/// plain text. AppKit/SwiftUI have no built-in "show password" control, so
/// this swaps between a `SecureField` and a `TextField` bound to the same
/// text depending on `isRevealed`.
private struct RevealablePasswordField: View {
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField("Password", text: $text)
                } else {
                    SecureField("Password", text: $text)
                }
            }
            .visibleFieldBorder()

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isRevealed ? "Hide password" : "Show password")
        }
    }
}
