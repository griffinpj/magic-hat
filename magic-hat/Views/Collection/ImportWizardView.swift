//
//  ImportWizardView.swift
//  magic-hat
//
//  Second half of the import flow: given already-parsed ManaBox rows, choose
//  which binders to import and whether to add-to or replace existing binders,
//  then apply via ImportController (which records the change in the audit
//  ledger). File picking/parsing happens in CollectionView before this opens.
//

import SwiftUI
import SwiftData

struct ImportWizardView: View {
    let rows: [ManaBoxRow]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Binder names that already exist, to flag add-vs-replace decisions.
    @Query private var existingEntries: [CollectionEntry]

    @State private var selected: Set<String> = []
    @State private var mode: ImportMode = .add
    @State private var summary: ImportController.Summary?
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var progress = ImportProgress()

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    /// Card counts per binder in the parsed file.
    private var binderCounts: [(name: String, count: Int)] {
        Dictionary(grouping: rows, by: \.binderName)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.quantity }) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private var existingBinderNames: Set<String> {
        Set(existingEntries.map(\.binderName))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(summary == nil ? "Choose Binders" : "Import Complete")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isImporting)
                    }
                    if summary == nil && !isImporting {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Import") { runImport() }
                                .disabled(selected.isEmpty)
                        }
                    }
                }
                .alert("Import Error", isPresented: errorBinding) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
        .onAppear {
            if selected.isEmpty { selected = Set(rows.map(\.binderName)) }
        }
    }

    @ViewBuilder private var content: some View {
        if isImporting {
            importingStep
        } else if let summary {
            doneStep(summary)
        } else {
            chooseBindersStep
        }
    }

    private var importingStep: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 280)
            Text("Importing \(Int(progress.fraction * 100))%")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chooseBindersStep: some View {
        Form {
            Section {
                Picker("When binder exists", selection: $mode) {
                    Text("Add to binder").tag(ImportMode.add)
                    Text("Replace binder").tag(ImportMode.replace)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(mode == .add
                     ? "New copies are added to matching binders; quantities merge."
                     : "Selected binders are cleared, then filled from this file.")
            }

            Section("Binders (\(rows.count) rows)") {
                ForEach(binderCounts, id: \.name) { binder in
                    Button {
                        toggle(binder.name)
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(binder.name)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(binder.name)
                                                 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(binder.name).foregroundStyle(.primary)
                                if existingBinderNames.contains(binder.name) {
                                    Text("Already in collection")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Text("\(binder.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func doneStep(_ summary: ImportController.Summary) -> some View {
        ContentUnavailableView {
            Label("Import Complete", systemImage: "checkmark.circle.fill")
        } description: {
            Text("Added \(summary.added) copies"
                 + (summary.removed > 0 ? ", removed \(summary.removed)." : ".")
                 + "\nBinders: \(summary.binders.joined(separator: ", "))")
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Actions

    private func toggle(_ name: String) {
        if selected.contains(name) { selected.remove(name) }
        else { selected.insert(name) }
    }

    private func runImport() {
        isImporting = true
        progress.fraction = 0

        Task {
            do {
                let result = try await ImportController.apply(
                    rows: rows,
                    selectedBinders: selected,
                    mode: mode,
                    context: modelContext
                ) { fraction in
                    progress.fraction = fraction
                }
                summary = result
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}

/// Observable progress holder the wizard binds its loading bar to.
@MainActor
@Observable
final class ImportProgress {
    var fraction: Double = 0
}

#Preview {
    ImportWizardView(rows: [])
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
