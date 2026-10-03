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
//  card, and the card is the whole affordance. The overview card *is* All
//  Collection: its totals are that scope's, so the card opens it — there
//  used to be a bare "All Collection" row under it saying nothing the
//  card didn't. The overview says more than two numbers: up or down since
//  bought (over the rows that know what was paid), the colours of the
//  whole collection as a bar, unique cards, sets, foils and the share in
//  decks — all from the one pass the store already makes per stamp.
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
    @State private var showingSettings = false
    /// The kind the name alert creates; kept after it closes, since the
    /// alert's button runs as it dismisses.
    @State private var creatingKind: CollectionKind = .collection
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var createError: String?
    @State private var parsedRows: [ManaBoxRow] = []
    @State private var parsedBinders: [ImportWizardView.BinderCount] = []
    @State private var showingWizard = false
    /// A file that isn't a ManaBox export: read by CardListReader, into a
    /// collection or list chosen in the sheet.
    @State private var genericFile: GenericFile?
    struct GenericFile: Identifiable {
        let text: String
        let name: String
        var id: String { name }
    }
    @State private var showingTextImport = false
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
    @AppStorage("collection.sort.direction") private var sortDirectionRaw: String = ""

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
            let order = CardOrder(sortRaw: sortRaw, directionRaw: sortDirectionRaw)
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
            try? await store.prewarmSnapshots(order: order, stamp: stamp)
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
                        Label("No Collections", systemImage: "tray")
                    } description: {
                        Text("No collections yet.\nImport a ManaBox export, or start a collection or a list, from the “…” menu.")
                    }
                } else {
                    collectionList
                }
            }
            .navigationTitle("Collections")
            .navigationDestination(for: String.self) { CollectionCardsView(collectionName: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        .accessibilityIdentifier("open-settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New Collection…", systemImage: CollectionKind.collection.systemImage) { startCreate(.collection) }
                            .accessibilityIdentifier("new-collection-menu")
                        Button("New List…", systemImage: CollectionKind.list.systemImage) { startCreate(.list) }
                            .accessibilityIdentifier("new-list-menu")
                        Divider()
                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Import a File…", systemImage: "square.and.arrow.down")
                        }
                        .accessibilityIdentifier("collections-import-file")
                        Button {
                            showingTextImport = true
                        } label: {
                            Label("Paste a List…", systemImage: "doc.on.clipboard")
                        }
                        .accessibilityIdentifier("collections-import-text")
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("collections-menu")
                }
            }
            .overlay { if isParsing || isDeleting { busyOverlay(isDeleting ? "Deleting…" : "Reading file…") } }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text, .utf8PlainText, .xml, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFile(result)
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingTextImport) {
                CollectionImportView(collectionName: nil, isList: false)
            }
            .sheet(item: $genericFile) { file in
                CollectionImportView(collectionName: nil, isList: false, fileText: file.text, fileName: file.name)
            }
            .sheet(isPresented: $showingWizard) {
                ImportWizardView(
                    rows: parsedRows,
                    binderCounts: parsedBinders,
                    existingCollectionNames: collections.map(\.name)
                )
            }
            .alert(creatingKind == .list ? "New List" : "New Collection", isPresented: $showingCreate) {
                TextField("Name", text: $newName)
                    .textInputAutocapitalization(.words)
                Button("Create") { create() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(creatingKind == .list
                     ? "Cards you want, not cards you have — a wishlist or a trade list. They don't count toward your collection."
                     : "An empty collection you can add cards to.")
            }
            .alert("Couldn't Create", isPresented: Binding(get: { createError != nil }, set: { if !$0 { createError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(createError ?? "")
            }
            .alert("Couldn't Import", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .task(id: tracker.revision) { scheduleSummaries(delay: .zero) }
            // The wizard over a file the UI test names, since a test can't
            // drive the document picker (`FeatureTour`'s import shots).
            .task {
                guard UITestSeed.isSeededRun,
                      let path = ProcessInfo.processInfo.environment["UITEST_WIZARD_FILE"], !path.isEmpty else { return }
                handleFile(.success([URL(fileURLWithPath: path)]))
            }
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

    private func startCreate(_ kind: CollectionKind) {
        newName = ""
        creatingKind = kind
        showingCreate = true
    }

    private func create() {
        let kind = creatingKind
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if try CollectionEditController.createCollection(named: name, kind: kind, context: modelContext) {
                path.append(name)
            } else {
                createError = name.isEmpty ? "Give it a name." : "“\(name)” is already taken by a collection or list."
            }
        } catch {
            createError = error.localizedDescription
        }
    }

    private var isPendingDeleteList: Bool {
        collections.first { $0.name == pendingDelete }?.kind == .list
    }

    private var ownedCollections: [MTGCollection] { collections.filter { $0.kind == .collection } }
    private var lists: [MTGCollection] { collections.filter { $0.kind == .list } }

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
                    // Everything owned, in one grid: collections and built
                    // decks alike. The card is the way in.
                    Button {
                        path.append(CollectionScope.allKey)
                    } label: {
                        LibraryOverviewCard(overview: overview)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("collection-all")
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
            if !ownedCollections.isEmpty {
                heading("Collections", count: ownedCollections.count)
                ForEach(ownedCollections) { collection in
                    collectionRow(collection)
                }
            }
            if !lists.isEmpty {
                // Lists: cards wanted, not held. Their own heading, below
                // everything that counts toward the totals above.
                heading("Lists", count: lists.count)
                ForEach(lists) { list in
                    collectionRow(list)
                }
            }
        }
        .listStyle(.plain)
        .confirmationDialog(
            "Delete “\(pendingDelete ?? "")”?",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button(isPendingDeleteList ? "Delete List" : "Delete Collection", role: .destructive) {
                if let name = pendingDelete { delete(name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every card in it. The change is recorded in History.")
        }
    }

    /// A section's title with its count, in the large-title's voice.
    private func heading(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            if count > 1 {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 2, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func collectionRow(_ collection: MTGCollection) -> some View {
        Button {
            path.append(collection.name)
        } label: {
            CollectionCard(summary: summary(for: collection.name), name: collection.name,
                           isList: collection.kind == .list)
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
                case .other(let text, let name):
                    genericFile = GenericFile(text: text, name: name)
                case .failure(let message):
                    importError = message
                }
            }
        }
    }

    private enum ParseOutcome: Sendable {
        case rows([ManaBoxRow], binders: [ImportWizardView.BinderCount])
        /// Not a ManaBox export: any other list or table, for the generic sheet.
        case other(text: String, name: String)
        case failure(String)
    }

    /// Reads and parses the file off the main thread so picking a large
    /// file never stalls the UI. A ManaBox export becomes rows for the
    /// wizard (it keeps ManaBox's ids and dates); anything else — another
    /// app's CSV, a list, an MTGO .dek — is read by CardListReader in the
    /// import sheet, which used to be reachable only from inside a
    /// collection.
    private static func parse(url: URL) async -> ParseOutcome {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                        ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) else {
                    return .failure("Couldn't read the file as text.")
                }
                guard CardListReader.read(text).isManaBox else { return .other(text: text, name: url.lastPathComponent) }
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

    @Environment(\.showsPrices) private var showsPrices
    private var all: CollectionSummary { overview.all }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text(CollectionScope.allName)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline) {
                stat(all.totalCopies.formatted(), "cards", id: "library-cards")
                Spacer(minLength: 12)
                if showsPrices {
                    stat(Self.money(all.totalValue), "market value", id: "library-value", alignment: .trailing)
                } else {
                    stat(all.uniqueCards.formatted(), "unique", id: "library-unique", alignment: .trailing)
                }
            }
            if showsPrices, let change = all.gainLoss, change.amount != 0 {
                gainLine(change)
            }
            if let counts = all.colorCounts, !counts.isEmpty {
                ColorBar(counts: counts)
                    .frame(height: 8)
            }
            Text(factsLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .monospacedDigit()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// "▲ $412 · +5.3% since bought", green up, red down — the rows that
    /// know what was paid, against what they are worth today.
    private func gainLine(_ change: (amount: Double, percent: Double)) -> some View {
        let up = change.amount > 0
        return HStack(spacing: 5) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.caption.weight(.bold))
            Text("\(PriceFormat.whole(abs(change.amount))) · \(PriceFormat.percent(change.percent)) since bought")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(up ? Color.green : Color.red)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-change")
    }

    /// "3,861 unique · 118 sets · 212 foils · 1,012 in decks".
    private var factsLine: String {
        var parts = ["\(all.uniqueCards.formatted()) unique"]
        if let sets = all.sets, sets > 0 { parts.append("\(sets.formatted()) \(sets == 1 ? "set" : "sets")") }
        if let foils = all.foils, foils > 0 { parts.append("\(foils.formatted()) \(foils == 1 ? "foil" : "foils")") }
        if overview.deckCopies > 0 { parts.append("\(overview.deckCopies.formatted()) in decks") }
        return parts.joined(separator: " · ")
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

    private static func money(_ value: Double) -> String {
        PriceFormat.whole(value)
    }
}

#Preview {
    CollectionsView()
        .modelContainer(for: [MTGCollection.self, CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
