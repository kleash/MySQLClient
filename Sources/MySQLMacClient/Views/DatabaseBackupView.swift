import SwiftUI

/// The "Backup..." sheet, opened from a database's context menu in the
/// sidebar. Modeled on HeidiSQL's "SQL Dump" dialog: a database picker, a
/// scrollable four-category object tree, a structure/data mode selector,
/// two option cards, a file-path row, and a live progress footer. Shares
/// `SchemaModalTheme`'s visual language with Create/Alter Table and
/// `TableExportView`.
struct DatabaseBackupView: View {
    @StateObject private var viewModel: DatabaseBackupViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var theme: SchemaModalTheme { SchemaModalTheme(colorScheme: colorScheme) }

    init(service: MySQLService, database: DatabaseInfo) {
        _viewModel = StateObject(wrappedValue: DatabaseBackupViewModel(service: service, database: database))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleRow
            databasePicker

            if viewModel.isLoadingObjects {
                ProgressView("Loading objects…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    objectsPanel
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            modeSelector
                            sourceOptionsCard
                            fileOptionsCard
                            saveToFileRow
                        }
                    }
                }
            }

            if let loadWarning = viewModel.loadWarning {
                Text(loadWarning)
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            statusFooter
        }
        .padding(24)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 640, idealHeight: 720)
        .background(theme.windowBackground)
        .task { await viewModel.loadDatabasesAndObjects() }
        .alert("Backup Complete", isPresented: $viewModel.didFinishSuccessfully) {
            Button("OK") {}
        } message: {
            Text("\(viewModel.database.name) was backed up successfully.")
        }
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SQL Dump")
                .font(.title2.bold())
                .foregroundColor(theme.textPrimary)
            Text("Export database to file · \(viewModel.database.name)")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: - Database picker

    private var databasePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DATABASE NAME")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
            Picker("", selection: Binding(
                get: { viewModel.database },
                set: { newDatabase in Task { await viewModel.selectDatabase(newDatabase) } }
            )) {
                ForEach(viewModel.availableDatabases) { database in
                    Text(database.name).tag(database)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
        }
    }

    // MARK: - Objects panel (scrollable, 4 categories)

    private var objectsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("OBJECTS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text("\(viewModel.selectedObjectCount) selected")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            HStack(spacing: 8) {
                Button("All") { viewModel.selectAllObjects() }
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                Button("None") { viewModel.selectNoObjects() }
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    categorySection(title: "Tables", items: viewModel.allTables, selection: Binding(
                        get: { viewModel.selectedTables }, set: { viewModel.selectedTables = $0 }
                    )) { $0.name }
                    categorySection(title: "Views", items: viewModel.allViews, selection: Binding(
                        get: { viewModel.selectedViews }, set: { viewModel.selectedViews = $0 }
                    )) { $0.name }
                    categorySection(title: "Stored Procedures", items: viewModel.allProcedures, selection: Binding(
                        get: { viewModel.selectedProcedures }, set: { viewModel.selectedProcedures = $0 }
                    )) { $0.name }
                    categorySection(title: "Functions", items: viewModel.allFunctions, selection: Binding(
                        get: { viewModel.selectedFunctions }, set: { viewModel.selectedFunctions = $0 }
                    )) { $0.name }
                    categorySection(title: "Triggers", items: viewModel.allTriggers, selection: Binding(
                        get: { viewModel.selectedTriggers }, set: { viewModel.selectedTriggers = $0 }
                    )) { $0.name }
                    categorySection(title: "Events", items: viewModel.allEvents, selection: Binding(
                        get: { viewModel.selectedEvents }, set: { viewModel.selectedEvents = $0 }
                    )) { $0.name }
                }
                .padding(10)
            }
            .frame(maxHeight: .infinity)
            .schemaCard(theme: theme)
        }
        .frame(width: 260)
    }

    /// One category (Tablolar/View'lar/Stored Procedure'lar/Function'lar):
    /// a header with a "select all in this category" checkbox + title +
    /// "selected/total" count, then one checkbox row per object. Generic
    /// over `TableInfo`/`RoutineInfo` — both `Identifiable & Hashable`
    /// already, so one implementation covers all four categories.
    ///
    /// Every checkbox here follows the mandatory
    /// `Toggle("", isOn:).labelsHidden()` + sibling `Text` shape —
    /// `SchemaCheckboxToggleStyle` silently drops any label passed into
    /// the `Toggle` itself (see `TableExportView.fieldsToExportSection`'s
    /// identical note).
    private func categorySection<Item: Identifiable & Hashable>(
        title: LocalizedStringKey,
        items: [Item],
        selection: Binding<Set<Item>>,
        name: @escaping (Item) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { !items.isEmpty && selection.wrappedValue.count == items.count },
                    set: { isOn in selection.wrappedValue = isOn ? Set(items) : [] }
                ))
                .labelsHidden()
                .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(selection.wrappedValue.count)/\(items.count)")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { selection.wrappedValue.contains(item) },
                        set: { isOn in
                            if isOn { selection.wrappedValue.insert(item) } else { selection.wrappedValue.remove(item) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
                    Text(name(item))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                }
                .padding(.leading, 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    if selection.wrappedValue.contains(item) { selection.wrappedValue.remove(item) } else { selection.wrappedValue.insert(item) }
                }
            }
        }
    }

    // MARK: - Mode selector (Yalnız yapı / Yalnız veri / Yapı + veri)

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EXPORT AS SQL")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: 6) {
                ForEach(DatabaseBackupMode.allCases) { mode in
                    modeTabButton(mode)
                }
            }
        }
    }

    private func modeTabButton(_ mode: DatabaseBackupMode) -> some View {
        let isActive = viewModel.options.mode == mode
        return Button {
            viewModel.options.mode = mode
        } label: {
            Text(mode.displayName)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .white : theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? theme.accent : theme.fieldBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: isActive ? 0 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Option cards

    private var sourceOptionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OPTIONS AFFECTING THE SOURCE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
            optionRow("Lock tables for reading", isOn: Binding(
                get: { viewModel.options.source.lockTablesForReading },
                set: { viewModel.options.source.lockTablesForReading = $0 }
            ))
            optionRow("Single transaction", isOn: Binding(
                get: { viewModel.options.source.useSingleTransaction },
                set: { viewModel.options.source.useSingleTransaction = $0 }
            ))
        }
        .padding(12)
        .schemaCard(theme: theme)
    }

    private var fileOptionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OPTIONS WRITTEN TO THE FILE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
            optionRow("Add \"USE database\" statement", isOn: Binding(
                get: { viewModel.options.file.includeUseStatement },
                set: { viewModel.options.file.includeUseStatement = $0 }
            ))
            optionRow("Add \"CREATE database\" statement", isOn: Binding(
                get: { viewModel.options.file.includeCreateDatabaseStatement },
                set: { viewModel.options.file.includeCreateDatabaseStatement = $0 }
            ))
            optionRow("Set FOREIGN_KEY_CHECKS=0", isOn: Binding(
                get: { viewModel.options.file.setForeignKeyChecksToZero },
                set: { viewModel.options.file.setForeignKeyChecksToZero = $0 }
            ))
            optionRow("Lock INSERT statements", isOn: Binding(
                get: { viewModel.options.file.lockInsertStatements },
                set: { viewModel.options.file.lockInsertStatements = $0 }
            ))
            optionRow("Generate extended INSERT statements", isOn: Binding(
                get: { viewModel.options.file.useExtendedInserts },
                set: { viewModel.options.file.useExtendedInserts = $0 }
            ))
            optionRow("Add \"DROP\" statements", isOn: Binding(
                get: { viewModel.options.file.includeDropStatements },
                set: { viewModel.options.file.includeDropStatements = $0 }
            ))
        }
        .padding(12)
        .schemaCard(theme: theme)
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

    // MARK: - Save to file

    private var saveToFileRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DESTINATION FILE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: 8) {
                Text(viewModel.outputFileURL?.path ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .schemaFieldBorder(theme: theme)
                Button("…") { viewModel.chooseOutputFile() }
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
            }
        }
    }

    // MARK: - Status footer

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = viewModel.progress {
                ProgressView(value: progress.percentage)
                HStack {
                    Text("\(progress.completedObjects)/\(progress.totalObjects) objects — \(progress.currentObjectDescription)")
                    Spacer()
                    Text("\(Int(progress.percentage * 100))%")
                }
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            }
            HStack {
                Text("\(viewModel.selectedObjectCount) objects ready · \(viewModel.options.mode.displayName)")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button("Close") {
                    if viewModel.isRunning { viewModel.cancelBackup() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                Button {
                    viewModel.startBackup()
                } label: {
                    if viewModel.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Export")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isRunning || viewModel.outputFileURL == nil || viewModel.selectedObjectCount == 0)
                .buttonStyle(SchemaPrimaryButtonStyle(theme: theme))
            }
        }
    }
}
