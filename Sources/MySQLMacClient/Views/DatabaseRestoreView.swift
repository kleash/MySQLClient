import SwiftUI

/// The "Restore..." sheet, opened from a database's context menu in the
/// sidebar next to "Backup...": a SQL file, two options, and live progress
/// with the statements the server refused. Shares `SchemaModalTheme`'s
/// visual language with `DatabaseBackupView`.
struct DatabaseRestoreView: View {
    @StateObject private var viewModel: DatabaseRestoreViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var theme: SchemaModalTheme { SchemaModalTheme(colorScheme: colorScheme) }

    init(service: MySQLService, database: DatabaseInfo) {
        _viewModel = StateObject(wrappedValue: DatabaseRestoreViewModel(service: service, database: database))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore SQL File")
                    .font(.title2.bold())
                    .foregroundColor(theme.textPrimary)
                Text("Run a SQL file · \(viewModel.database.name)")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
            }

            sourceFileRow
            enginePicker
            optionsCard

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if !viewModel.statementErrors.isEmpty {
                errorList
            }

            Spacer(minLength: 0)
            statusFooter
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 520)
        .background(theme.windowBackground)
        .task { await viewModel.locateExternalTool() }
        .alert("Restore Complete", isPresented: $viewModel.didFinishSuccessfully) {
            Button("OK") {}
        } message: {
            Text("\(viewModel.inputFileURL?.lastPathComponent ?? "") was restored.")
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(theme.textSecondary)
    }

    private var sourceFileRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("SOURCE FILE")
            HStack(spacing: 8) {
                Text(viewModel.inputFileURL?.path ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .schemaFieldBorder(theme: theme)
                Button("…") { viewModel.chooseInputFile() }
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                    .disabled(viewModel.isRunning)
            }
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("ENGINE")
            Picker("", selection: $viewModel.usesExternalTool) {
                Text("Built-in").tag(false)
                Text(verbatim: viewModel.externalToolURL?.lastPathComponent ?? "mysql").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            // All of it: a segmented picker ignores `.disabled` on one segment.
            .disabled(viewModel.isRunning || !ExternalTool.isAvailable || !viewModel.useDatabaseNamedInFile)
            Group {
                if !ExternalTool.isAvailable {
                    Text("The App Sandbox keeps this build from running command-line tools installed outside the app.")
                } else if !viewModel.useDatabaseNamedInFile {
                    Text("The mysql client follows the file's own USE statements: turn on \"Use the database named in the file\" to restore with it.")
                } else if viewModel.usesExternalTool, let toolURL = viewModel.externalToolURL {
                    Text(verbatim: toolURL.path)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                } else if viewModel.usesExternalTool {
                    Text("No mysql or mariadb client was found. Choose one in Settings ▸ General.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(theme.textSecondary)
        }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("OPTIONS")
            optionRow("Use the database named in the file (its USE and CREATE DATABASE statements)", isOn: $viewModel.useDatabaseNamedInFile)
            optionRow("Stop at the first failed statement", isOn: $viewModel.stopOnFirstError)
            Text("A SQL file can't be undone as a whole: if the restore stops part-way, the statements before that point stay restored.")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .schemaCard(theme: theme)
        .disabled(viewModel.isRunning)
    }

    private func optionRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
            Text(title)
                .foregroundStyle(theme.textPrimary)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }

    private var errorList: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("FAILED STATEMENTS")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.statementErrors) { error in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Line \(error.line): \(error.message)")
                                .foregroundStyle(.red)
                            Text(error.statement)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(3)
                        }
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: 160)
            .schemaCard(theme: theme)
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = viewModel.progress {
                ProgressView(value: progress.percentage)
                HStack {
                    Text("\(progress.statementsRun) statements run")
                    Spacer()
                    Text("\(Int(progress.percentage * 100))%")
                }
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            }
            HStack {
                Spacer()
                Button("Close") {
                    if viewModel.isRunning { viewModel.cancelRestore() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                Button {
                    viewModel.startRestore()
                } label: {
                    if viewModel.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Restore")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SchemaPrimaryButtonStyle(theme: theme))
                .disabled(viewModel.isRunning || viewModel.inputFileURL == nil
                          || (viewModel.usesExternalTool && viewModel.externalToolURL == nil))
            }
        }
    }
}
