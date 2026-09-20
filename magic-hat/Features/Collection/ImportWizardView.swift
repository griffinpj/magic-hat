//
//  ImportWizardView.swift
//  magic-hat
//
//  Wizard for importing a ManaBox CSV: pick a file, choose which binders to
//  import, decide whether to add-to or replace existing binders, then apply
//  via ImportService (which records the change in the audit ledger).
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportWizardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Binder names that already exist, to flag add-vs-replace decisions.
    @Query private var existingEntries: [CollectionEntry]

    private enum Step {
        case pickFile
        case chooseBinders
        case done(ImportService.Summary)
    }

    @State private var step: Step = .pickFile
    @State private var showingFileImporter = false
    @State private var rows: [ManaBoxRow] = []
    @State private var selected: Set<String> = []
    @State private var mode: ImportMode = .add
    @State private var errorMessage: String?

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
                .navigationTitle("Import Collection")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    if case .chooseBinders = step {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Import") { runImport() }
                                .disabled(selected.isEmpty)
                        }
                    }
                }
                .fileImporter(
                    isPresented: $showingFileImporter,
                    allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                    allowsMultipleSelection: false
                ) { result in
                    handleFile(result)
                }
                .alert("Import Error", isPresented: .constant(errorMessage != nil)) {
                    Button("OK") { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .pickFile:
            pickFileStep
        case .chooseBinders:
            chooseBindersStep
        case .done(let summary):
            doneStep(summary)
        }
    }

    // MARK: Steps

    private var pickFileStep: some View {
        ContentUnavailableView {
            Label("Choose a File", systemImage: "doc.badge.plus")
        } description: {
            Text("Select a ManaBox CSV export to import into your collection.")
        } actions: {
            Button("Select File…") { showingFileImporter = true }
                .buttonStyle(.borderedProminent)
        }
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

    private func doneStep(_ summary: ImportService.Summary) -> some View {
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

    private func handleFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let parsed = try CSVParser.parseManaBox(text)
                guard !parsed.isEmpty else {
                    errorMessage = "No card rows found in the file."
                    return
                }
                rows = parsed
                selected = Set(parsed.map(\.binderName))
                step = .chooseBinders
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runImport() {
        do {
            let summary = try ImportService.apply(
                rows: rows,
                selectedBinders: selected,
                mode: mode,
                context: modelContext
            )
            step = .done(summary)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    ImportWizardView()
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
