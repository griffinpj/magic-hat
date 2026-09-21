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

struct CollectionsView: View {
    @Environment(\.modelContext) private var modelContext

    // Small table; fine as a live query and it gives the list its identity.
    @Query(sort: \MTGCollection.name) private var collections: [MTGCollection]

    private var tracker: CollectionChangeTracker { .shared }
    private var hydrator: CardHydrationController { .shared }
    private var store: CollectionStore { CollectionStore.shared(for: modelContext.container) }

    @State private var showingFileImporter = false
    @State private var parsedRows: [ManaBoxRow] = []
    @State private var showingWizard = false
    @State private var importError: String?
    @State private var isParsing = false
    @State private var summaries: [CollectionSummary] = []
    @State private var summaryTask: Task<Void, Never>?
    @State private var pendingDelete: String?
    @State private var isDeleting = false

    private var errorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    /// Totals + top cards, computed off-main by the store. Debounced because
    /// hydration bumps its revision on every 75-card batch.
    private func scheduleSummaries(delay: Duration) {
        summaryTask?.cancel()
        summaryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if let fresh = try? await store.summaries(), !Task.isCancelled {
                summaries = fresh
            }
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
            .task(id: tracker.revision) {
                await backfillCollections()
                scheduleSummaries(delay: .zero)
            }
            .onChange(of: hydrator.revision) { _, _ in
                scheduleSummaries(delay: hydrator.isSyncing ? .seconds(2) : .milliseconds(300))
            }
        }
    }

    /// Ensures an MTGCollection row exists for every collection name present on
    /// entries. Covers data imported before collections were modeled.
    private func backfillCollections() async {
        guard let names = try? await store.entryCollectionNames() else { return }
        let missing = names.subtracting(collections.map(\.name))
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
                CollectionCard(summary: summary(for: collection.name), name: collection.name)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    pendingDelete = collection.name
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .listStyle(.plain)
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

    /// Collection card: what the collection is worth, how big it is, and a fan
    /// of its most valuable cards. Glass is affordable here — there are a
    /// handful of these, and each is a navigation target, unlike the hundreds
    /// of content tiles in the grid.
    private struct CollectionCard: View {
        let summary: CollectionSummary?
        let name: String

        private var valueText: String {
            guard let value = summary?.totalValue, value > 0 else { return "—" }
            return value >= 1000
                ? String(format: "$%.0f", value)
                : String(format: "$%.2f", value)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        if let s = summary {
                            Text("\(s.totalCopies) cards · \(s.uniqueCards) unique")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(valueText)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Text("MARKET")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }

                if let highlights = summary?.highlights, !highlights.isEmpty {
                    highlightFan(highlights)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }

        /// Overlapped like a hand of cards, most valuable in front.
        private func highlightFan(_ highlights: [CollectionSummary.Highlight]) -> some View {
            HStack(spacing: -22) {
                ForEach(Array(highlights.enumerated().reversed()), id: \.element.id) { index, card in
                    CardImageView(
                        urlString: card.imageURL,
                        aspectRatio: card.aspectRatio,
                        cornerRadius: 5,
                        targetWidth: 80
                    )
                    .frame(width: 50)
                    .rotationEffect(.degrees(Double(index) * -2.5))
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                    .zIndex(Double(highlights.count - index))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
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
