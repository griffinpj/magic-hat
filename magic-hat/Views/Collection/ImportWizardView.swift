//
//  ImportWizardView.swift
//  magic-hat
//
//  Second half of the import flow: given already-parsed ManaBox rows, choose
//  a destination collection (new or existing) and which binders to import,
//  then apply via ImportController (which records the change in the audit
//  ledger). File picking/parsing happens in CollectionsView before this opens.
//

import SwiftUI
import SwiftData

struct ImportWizardView: View {
    let rows: [ManaBoxRow]
    /// Existing collection names, offered as import destinations.
    let existingCollectionNames: [String]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum Destination: Hashable {
        case new
        case existing
    }

    @State private var destination: Destination = .new
    @State private var newName: String = "New Collection"
    @State private var selectedCollection: String = ""
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

    /// The resolved destination collection name, or nil if invalid.
    private var resolvedCollectionName: String? {
        switch destination {
        case .new:
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .existing:
            return selectedCollection.isEmpty ? nil : selectedCollection
        }
    }

    private var canImport: Bool {
        resolvedCollectionName != nil && !selected.isEmpty
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(summary == nil ? "Import" : "Import Complete")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isImporting)
                    }
                    if summary == nil && !isImporting {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Import") { runImport() }
                                .disabled(!canImport)
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
            if existingCollectionNames.isEmpty {
                destination = .new
            } else if selectedCollection.isEmpty {
                selectedCollection = existingCollectionNames[0]
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isImporting {
            importingStep
        } else if let summary {
            doneStep(summary)
        } else {
            chooseStep
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

    private var chooseStep: some View {
        Form {
            destinationSection
            bindersSection
        }
    }

    @ViewBuilder private var destinationSection: some View {
        Section("Destination") {
            Picker("Import into", selection: $destination) {
                Text("New Collection").tag(Destination.new)
                Text("Existing Collection")
                    .tag(Destination.existing)
            }
            .pickerStyle(.segmented)
            .disabled(existingCollectionNames.isEmpty)

            switch destination {
            case .new:
                TextField("Collection name", text: $newName)
                    .textInputAutocapitalization(.words)
            case .existing:
                Picker("Collection", selection: $selectedCollection) {
                    ForEach(existingCollectionNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
        }

        if destination == .existing {
            Section {
                Picker("For selected binders", selection: $mode) {
                    Text("Add to binder").tag(ImportMode.add)
                    Text("Replace binder").tag(ImportMode.replace)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(mode == .add
                     ? "New copies merge into matching binders; quantities add up."
                     : "Selected binders in this collection are cleared, then filled from the file.")
            }
        }
    }

    private var bindersSection: some View {
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
                        Text(binder.name).foregroundStyle(.primary)
                        Spacer()
                        Text("\(binder.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func doneStep(_ summary: ImportController.Summary) -> some View {
        ContentUnavailableView {
            Label("Import Complete", systemImage: "checkmark.circle.fill")
        } description: {
            Text("“\(summary.collectionName)” — added \(summary.added) copies"
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
        guard let collectionName = resolvedCollectionName else { return }
        // A brand-new collection has nothing to replace.
        let effectiveMode: ImportMode = destination == .new ? .add : mode

        isImporting = true
        progress.fraction = 0

        Task {
            do {
                let result = try await ImportController.apply(
                    rows: rows,
                    selectedBinders: selected,
                    collectionName: collectionName,
                    mode: effectiveMode,
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
    ImportWizardView(rows: [], existingCollectionNames: ["My Library"])
        .modelContainer(for: [MTGCollection.self, CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
