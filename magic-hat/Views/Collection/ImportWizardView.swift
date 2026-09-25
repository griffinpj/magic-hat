//
//  ImportWizardView.swift
//  magic-hat
//
//  Second half of the import flow: given already-parsed ManaBox rows, choose
//  a destination collection (new or existing) and which of the file's binders
//  to take cards from, then apply via ImportController. The binders are only
//  a way to pick rows — everything selected lands in one collection with no
//  grouping inside it. File picking/parsing happens in CollectionsView.
//

import SwiftUI
import SwiftData

struct ImportWizardView: View {
    let rows: [ManaBoxRow]
    /// Card counts per binder in the parsed file, counted with the parse,
    /// off the main thread (`binderCounts(of:)`). As a computed property it
    /// regrouped every row on each keystroke; worked out in `init` it still
    /// did, on every update of the presenting tab — once per hydration
    /// batch while this sheet showed "Fetching card data".
    let binderCounts: [BinderCount]
    /// Existing collection names, offered as import destinations.
    let existingCollectionNames: [String]

    nonisolated struct BinderCount: Hashable, Sendable {
        let name: String
        let count: Int
    }

    nonisolated static func binderCounts(of rows: [ManaBoxRow]) -> [BinderCount] {
        Dictionary(grouping: rows, by: \.binderName)
            .map { BinderCount(name: $0.key, count: $0.value.reduce(0) { $0 + $1.quantity }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

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
    @State private var isFetchingCards = false
    @State private var progress = ImportProgress()

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
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

    private var newNameCollides: Bool {
        guard destination == .new, let name = resolvedCollectionName else { return false }
        return existingCollectionNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
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
            if selected.isEmpty { selected = Set(binderCounts.map(\.name)) }
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
        } else if isFetchingCards {
            fetchingStep
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

    /// Second phase of the import: pull down card data for what was just
    /// imported, so the collection is browsable and sortable immediately
    /// rather than syncing the first time it is opened. Dismissable — the
    /// work continues on the shared controller either way.
    private var fetchingStep: some View {
        let hydrator = CardHydrationController.shared
        return VStack(spacing: 20) {
            ProgressView(value: hydrator.syncFraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 280)
            Text("Fetching card data \(hydrator.syncedCount)/\(hydrator.syncTotal)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("Images and prices. You can close this — it keeps going.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
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
                if newNameCollides {
                    Label("A collection with this name exists — cards will be added to it.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
                Picker("Existing cards", selection: $mode) {
                    Text("Add to collection").tag(ImportMode.add)
                    Text("Replace collection").tag(ImportMode.replace)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(mode == .add
                     ? "Imported cards merge into the collection; matching copies add up."
                     : "Everything in the collection is removed first, then replaced with the imported cards.")
            }
        }
    }

    private var bindersSection: some View {
        Section {
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
        } header: {
            Text("Take cards from")
        } footer: {
            Text("Binders in the file. Everything you tick goes into the one collection above — the binder split isn't kept.")
        }
    }

    private func doneStep(_ summary: ImportController.Summary) -> some View {
        ContentUnavailableView {
            Label("Import Complete", systemImage: "checkmark.circle.fill")
        } description: {
            Text("“\(summary.collectionName)” — added \(summary.added) copies"
                 + (summary.removed > 0 ? ", removed \(summary.removed)." : ".")
                 + "\nFrom: \(summary.sourceBinders.joined(separator: ", "))")
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
                    container: modelContext.container
                ) { fraction in
                    progress.fraction = fraction
                }
                summary = result
                isImporting = false

                // Import is an attended action, so show the metadata fetch as
                // a second phase rather than letting it surprise the user the
                // first time they open the collection.
                isFetchingCards = true
                await CardHydrationController.shared.hydrateAll(
                    scryfallIDs: rows
                        .filter { selected.contains($0.binderName) }
                        .map(\.scryfallID),
                    context: modelContext
                )
                isFetchingCards = false
            } catch {
                errorMessage = error.localizedDescription
                isImporting = false
            }
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
    ImportWizardView(rows: [], binderCounts: [], existingCollectionNames: ["My Library"])
        .modelContainer(for: [MTGCollection.self, CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
