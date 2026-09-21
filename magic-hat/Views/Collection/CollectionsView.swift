//
//  CollectionsView.swift
//  magic-hat
//
//  Collection tab root: lists the named collections and hosts the "…" import
//  menu. Import picks a ManaBox CSV, parses it off-main, then opens the
//  wizard to choose a destination collection and which binders to import.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Aggregated stats for one collection.
private struct CollectionSummary: Identifiable {
    let name: String
    let uniqueCards: Int
    let totalCopies: Int
    var id: String { name }
}

struct CollectionsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \MTGCollection.name) private var collections: [MTGCollection]

    // Lightweight rows (only the columns needed to aggregate) for counts.
    @Query private var entries: [CollectionEntry]

    init() {
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.propertiesToFetch = [\.collectionName, \.quantity]
        _entries = Query(descriptor)
    }

    @State private var showingFileImporter = false
    @State private var parsedRows: [ManaBoxRow] = []
    @State private var showingWizard = false
    @State private var importError: String?
    @State private var isParsing = false
    @State private var summaries: [CollectionSummary] = []
    @State private var pendingDelete: String?
    @State private var isDeleting = false

    private var errorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private func rebuildSummaries() {
        let byCollection = Dictionary(grouping: entries, by: \.collectionName)
        summaries = collections.map { collection in
            let rows = byCollection[collection.name] ?? []
            return CollectionSummary(
                name: collection.name,
                uniqueCards: rows.count,
                totalCopies: rows.reduce(0) { $0 + $1.quantity }
            )
        }
    }

    private func summary(for name: String) -> CollectionSummary? {
        summaries.first { $0.name == name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if collections.isEmpty {
                    ContentUnavailableView {
                        Text("📭").font(.system(size: 64))
                    } description: {
                        Text("No collections yet.\nImport one from the “…” menu.")
                    }
                } else {
                    collectionList
                }
            }
            .navigationTitle("Collections")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .overlay { if isParsing || isDeleting { busyOverlay(isDeleting ? "Deleting…" : "Reading file…") } }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                allowsMultipleSelection: false
            ) { result in
                handleFile(result)
            }
            .sheet(isPresented: $showingWizard) {
                ImportWizardView(
                    rows: parsedRows,
                    existingCollectionNames: collections.map(\.name)
                )
            }
            .alert("Import Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .onChange(of: entries, initial: true) { _, _ in rebuildSummaries() }
            .onChange(of: collections, initial: true) { _, _ in rebuildSummaries() }
            .task { backfillCollections() }
        }
    }

    /// Ensures an MTGCollection row exists for every collection name present in
    /// entries. Covers data imported before collections were modeled.
    private func backfillCollections() {
        let names = Set(entries.map(\.collectionName)).filter { !$0.isEmpty }
        let existing = Set(collections.map(\.name))
        let missing = names.subtracting(existing)
        guard !missing.isEmpty else { return }
        for name in missing { modelContext.insert(MTGCollection(name: name)) }
        try? modelContext.save()
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func delete(_ name: String) {
        isDeleting = true
        Task {
            defer { isDeleting = false }
            _ = try? await CollectionEditController.delete(
                collectionName: name, context: modelContext
            )
        }
    }

    private var collectionList: some View {
        List(collections) { collection in
            NavigationLink {
                CollectionCardsView(collectionName: collection.name)
            } label: {
                HStack {
                    Image(systemName: "tray.full.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                            .font(.body.weight(.medium))
                        if let s = summary(for: collection.name) {
                            Text("\(s.totalCopies) cards · \(s.uniqueCards) unique")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    pendingDelete = collection.name
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete ?? "")”?",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Collection", role: .destructive) {
                if let name = pendingDelete { delete(name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every card in this collection. The change is recorded in History.")
        }
    }

    // Brief spinner shown while the picked CSV is read + parsed off-main.
    private func busyOverlay(_ label: String) -> some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isParsing = true
            Task {
                let outcome = await Self.parse(url: url)
                isParsing = false
                switch outcome {
                case .rows(let rows):
                    parsedRows = rows
                    showingWizard = true
                case .failure(let message):
                    importError = message
                }
            }
        }
    }

    private enum ParseOutcome: Sendable {
        case rows([ManaBoxRow])
        case failure(String)
    }

    /// Reads and parses the CSV off the main thread so picking a large file
    /// never stalls the UI. Returns rows or a user-facing error message.
    private static func parse(url: URL) async -> ParseOutcome {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
                    return .failure("Couldn't read the file as text.")
                }
                let rows = try CSVParser.parseManaBox(text)
                guard !rows.isEmpty else {
                    return .failure("No card rows found in the file.")
                }
                return .rows(rows)
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }
}

#Preview {
    CollectionsView()
        .modelContainer(for: [MTGCollection.self, CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
