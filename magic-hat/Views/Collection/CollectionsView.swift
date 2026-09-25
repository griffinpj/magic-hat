//
//  CollectionsView.swift
//  magic-hat
//
//  Collection tab root: an overview of everything owned (cards, value, how
//  much sits in built decks), the synthetic "All Collection", then the
//  named collections; and the "…" import menu. Import picks a ManaBox CSV,
//  parses it off-main, then opens the wizard to choose a destination
//  collection and which binders to import.
//
//  The rows are glass cards that push through a navigation path, not
//  NavigationLinks: a link in a List draws a disclosure chevron beside the
//  card, and the card is the whole affordance. All Collection is its name
//  alone — its count and value are the overview card right above it.
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
    @State private var parsedBinders: [ImportWizardView.BinderCount] = []
    @State private var showingWizard = false
    @State private var importError: String?
    @State private var isParsing = false
    /// Starts as the last overview saved (see `LastOverview`), so the
    /// tab's first frame already has its numbers.
    @State private var overview: CollectionOverview? = LastOverview.saved
    @State private var summaryTask: Task<Void, Never>?
    /// A refresh came due while a collection was pushed on top.
    @State private var summariesStale = false
    /// Names already backfilled this session, so a query that hasn't
    /// caught up yet can't make the backfill (and the recount) repeat.
    @State private var backfilled: Set<String> = []
    @State private var pendingDelete: String?
    @State private var isDeleting = false
    /// Collection names (or `CollectionScope.allKey`) pushed onto the stack.
    @State private var path: [String] = []
    /// The grid's sort, so the overview pass can leave each collection's
    /// snapshot ready in that order.
    @AppStorage("collection.sort") private var sortRaw: String = CardSort.name.rawValue

    private var errorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    /// Totals + top cards, computed off-main by the store. Debounced because
    /// hydration bumps its revision on every 75-card batch. The totals come
    /// first and land on the tab; the per-collection snapshots (every
    /// collection sorted) are prewarmed right after from the same rows, so
    /// the tab fills in one pass rather than waiting for all of them.
    ///
    /// Skipped while a collection is pushed on top: the tab isn't showing,
    /// and during a sync each pass re-read every row on the store's queue —
    /// the queue the pushed grid's own refreshes wait on. It runs once on
    /// the way back instead.
    private func scheduleSummaries(delay: Duration) {
        guard path.isEmpty else { summariesStale = true; return }
        summaryTask?.cancel()
        summaryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let sort = CardSort(rawValue: sortRaw) ?? .name
            let stamp = StoreStamp.current
            if let fresh = try? await store.overview(stamp: stamp), !Task.isCancelled {
                overview = fresh
                // A collection only rows knew about: now that it has its
                // MTGCollection, count it too (same stamp, rows cached).
                if backfillCollections(fresh.entryCollectionNames) {
                    scheduleSummaries(delay: .zero)
                    return
                }
                LastOverview.save(fresh)
            }
            guard !Task.isCancelled else { return }
            try? await store.prewarmSnapshots(sort: sort, stamp: stamp)
        }
    }

    private func summary(for name: String) -> CollectionSummary? {
        overview?.collections.first { $0.name == name }
    }

    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationDestination(for: String.self) { CollectionCardsView(collectionName: $0) }
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
                    binderCounts: parsedBinders,
                    existingCollectionNames: collections.map(\.name)
                )
            }
            .alert("Import Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .task(id: tracker.revision) { scheduleSummaries(delay: .zero) }
            // Observed in a child, not with onChange here: reading the
            // revision in this body re-rendered the tab — and re-created the
            // import sheet's content — on every hydration batch.
            .background {
                HydrationObserver {
                    scheduleSummaries(delay: hydrator.isSyncing ? .seconds(2) : .milliseconds(300))
                }
            }
            .onChange(of: path.isEmpty) { _, isEmpty in
                if isEmpty, summariesStale {
                    summariesStale = false
                    scheduleSummaries(delay: .zero)
                }
            }
        }
    }

    /// Ensures an MTGCollection row exists for every collection name present on
    /// entries. Covers data imported before collections were modeled. The
    /// names come with the overview — a separate pass over every row used
    /// to run ahead of it on each launch and each write.
    private func backfillCollections(_ names: Set<String>) -> Bool {
        let missing = names.subtracting(collections.map(\.name)).subtracting(backfilled)
        guard !missing.isEmpty else { return false }
        backfilled.formUnion(missing)
        for name in missing { modelContext.insert(MTGCollection(name: name)) }
        try? modelContext.save()
        return true
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
        List {
            if let overview {
                if overview.all.totalCopies > 0 {
                    LibraryOverviewCard(overview: overview)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                // The totals are one pass over every owned row, off the main
                // actor; on a big collection that is a moment. Say so where
                // the numbers will land, rather than showing an empty card.
                LibraryLoadingCard()
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            // Everything in one grid: collections and built decks alike.
            Button {
                path.append(CollectionScope.allKey)
            } label: {
                CollectionCard(summary: nil, name: CollectionScope.allName, showsValue: false)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("collection-all")
            ForEach(collections) { collection in
                Button {
                    path.append(collection.name)
                } label: {
                    CollectionCard(summary: summary(for: collection.name), name: collection.name)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("collection-\(collection.name)")
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
                case .rows(let rows, let binders):
                    parsedRows = rows
                    parsedBinders = binders
                    showingWizard = true
                case .failure(let message):
                    importError = message
                }
            }
        }
    }

    private enum ParseOutcome: Sendable {
        case rows([ManaBoxRow], binders: [ImportWizardView.BinderCount])
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
                return .rows(rows, binders: ImportWizardView.binderCounts(of: rows))
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }
}

/// Cards, value, and the share built into decks — two numbers and a bar.
/// Glass like the collection cards; the same shape at the top of the list.
/// The overview card's place while the store adds the collection up.
struct LibraryLoadingCard: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Adding up your collection…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("library-loading")
    }
}

struct LibraryOverviewCard: View {
    let overview: CollectionOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                stat(overview.all.totalCopies.formatted(), "cards", id: "library-cards")
                Spacer(minLength: 12)
                stat(Self.money(overview.all.totalValue), "market value", id: "library-value", alignment: .trailing)
            }
            if overview.deckCopies > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            Capsule().fill(.tint)
                                .frame(width: max(4, geo.size.width * overview.deckFraction))
                            Capsule().fill(.quaternary)
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        legend(.tint, "\(overview.deckCopies.formatted()) in decks")
                        Spacer()
                        legend(.quaternary, "\(overview.collectionCopies.formatted()) in collections")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(overview.deckCopies) cards in decks, \(overview.collectionCopies) in collections")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func stat(_ value: String, _ label: String, id: String, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(value)
                .font(.title.weight(.bold))
                .monospacedDigit()
                .accessibilityIdentifier(id)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    private func legend(_ fill: some ShapeStyle, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(fill).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private static func money(_ value: Double) -> String {
        PriceFormat.whole(value)
    }
}

#Preview {
    CollectionsView()
        .modelContainer(for: [MTGCollection.self, CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
