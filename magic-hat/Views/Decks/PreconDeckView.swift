//
//  PreconDeckView.swift
//  magic-hat
//
//  A preconstructed deck, read-only, in the deck screen's own shape:
//  Cards / Stats / Details as pages under a segmented bar, the search
//  field filtering the list, the viewer from a row — the list drawn
//  locked (×n, no stepper, no swaps or Try Cards, nothing that adds a
//  card, since the deck isn't the user's yet). Every row says whether
//  the collection holds the card. One prominent action, Import, in a
//  bottom bar: it asks where the deck goes (the folder sheet a move
//  uses), then makes a new deck with this list there, which opens in the
//  precon's place.
//
//  Details is its own page: a printed deck has a type, a set, a release
//  date and a source instead of notes, versions and a lock.
//

import SwiftUI
import SwiftData

struct PreconDeckView: View {
    let fileName: String
    /// Called with the new deck's id after Import, so the tab can open it.
    let onImported: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var controller = PreconController.shared
    @State private var deck: MTGJSONDeck?
    @State private var snapshot: DeckSnapshot?
    @State private var unresolved: [String] = []
    @State private var error: String?
    @State private var tab: DeckDetailView.Tab = .cards
    @State private var filterText = ""
    @State private var searchSessionActive = false
    @State private var viewer: CardViewerSession?
    @State private var importing = false
    @State private var choosingFolder = false
    /// The folder chosen in the sheet (`.some(nil)`: the top level); the
    /// import runs once the sheet has gone, and the deck opens after it.
    @State private var importFolder: UUID??
    @Namespace private var zoom

    private var collectionTracker: CollectionChangeTracker { .shared }
    private var summary: MTGJSONDeckSummary? { controller.summary(fileName: fileName) }

    var body: some View {
        pages
            .background {
                SearchDismisser(isEmpty: filterText.isEmpty)
                SearchSessionReporter(isActive: $searchSessionActive)
            }
            .navigationTitle(snapshot?.name ?? summary?.name ?? "Preconstructed Deck")
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filterText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this deck")
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .navigationBarBackButtonHidden(searchSessionActive)
            // On the screen, not the bar's button: where the deck goes.
            .sheet(isPresented: $choosingFolder, onDismiss: {
                if let folder = importFolder {
                    importFolder = nil
                    Task { await importDeck(into: folder) }
                }
            }) {
                DeckFolderPicker(title: "Import To", subtitle: deck?.name ?? summary?.name, createLabel: "Create and Import") { folder in
                    importFolder = .some(folder)
                }
            }
            .onChange(of: searchSessionActive) { _, active in if active { tab = .cards } }
            .onChange(of: filterText) { _, text in if !text.isEmpty { tab = .cards } }
            .toolbar {
                if let snapshot {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            BuyMenu(title: "Buy Missing Cards", lines: snapshot.missingBuyLines)
                            BuyMenu(title: "Buy the Whole Deck", lines: snapshot.allBuyLines)
                            if let source = deck?.source, let url = URL(string: source) {
                                Divider()
                                Link(destination: url) { Label("Source", systemImage: "safari") }
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                        .accessibilityIdentifier("precon-menu")
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                if snapshot != nil, !searchSessionActive { importBar }
            }
            .fullScreenCover(item: $viewer) { v in
                CardViewerView(items: v.items, currentID: Bindable(v).currentID)
                    .navigationTransition(.zoom(sourceID: v.currentID ?? "", in: zoom))
            }
            .alert("Something Went Wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .task(id: "\(fileName)|\(collectionTracker.revision)") { await load() }
    }

    private var subtitle: String {
        if let snapshot { return snapshot.subtitle }
        return summary?.type ?? ""
    }

    private var pages: some View {
        Group {
            if let snapshot {
                TabView(selection: $tab) {
                    DeckCardsView(snapshot: snapshot, filterText: filterText, onAddCards: {}, zoom: zoom, viewer: viewer,
                                  onOpenViewer: { viewer = $0 })
                        .tag(DeckDetailView.Tab.cards)
                    DeckStatsView(snapshot: snapshot)
                        .tag(DeckDetailView.Tab.stats)
                    PreconDetailsView(snapshot: snapshot, deck: deck, summary: summary, unresolved: unresolved)
                        .tag(DeckDetailView.Tab.details)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .background(tab == .cards ? Color(.systemBackground) : Color(.systemGroupedBackground), ignoresSafeAreaEdges: .all)
                .animation(.default, value: tab)
                .safeAreaBar(edge: .top) {
                    Picker("Section", selection: $tab) {
                        ForEach(DeckDetailView.Tab.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("precon-tabs")
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn't Load the Deck", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the deck list…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The one thing to do with a precon that isn't yours yet.
    private var importBar: some View {
        Button {
            choosingFolder = true
        } label: {
            Label(importing ? "Importing…" : "Import as a Deck", systemImage: "square.and.arrow.down")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .disabled(importing)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .accessibilityIdentifier("precon-import")
    }

    private func load() async {
        if controller.phase != .loaded { await controller.load() }
        do {
            let loaded = try await controller.deck(fileName: fileName)
            deck = loaded
            let container = modelContext.container
            let store = DeckStore.shared(for: container)
            let result = try await store.preconSnapshot(loaded, writer: CardMetaWriter.shared(for: container))
            guard !Task.isCancelled else { return }
            snapshot = result.snapshot
            unresolved = result.unresolved
            error = nil
        } catch is CancellationError {
        } catch {
            if snapshot == nil { self.error = error.localizedDescription }
        }
    }

    /// Makes the deck in `folder`, then opens it; the bar says
    /// "Importing…" while the rows go in (it used to be set and cleared
    /// inside one synchronous call, so it never drew).
    private func importDeck(into folder: UUID?) async {
        guard let deck, !importing else { return }
        importing = true
        defer { importing = false }
        do {
            let id = try await controller.importDeck(deck, into: folder, context: modelContext)
            onImported(id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What a printed deck says about itself: its product line, set and
/// date, where the list came from, what it holds and how much of it the
/// collection already has.
private struct PreconDetailsView: View {
    let snapshot: DeckSnapshot
    let deck: MTGJSONDeck?
    let summary: MTGJSONDeckSummary?
    let unresolved: [String]

    @Environment(\.showsPrices) private var showsPrices

    private var ownedCopies: Int { snapshot.playedItems.reduce(0) { $0 + $1.availableQuantity } }
    private var missing: Int { snapshot.playedItems.reduce(0) { $0 + $1.missingQuantity } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Product", value: deck?.type ?? summary?.type ?? "Preconstructed deck")
                LabeledContent("Set") {
                    HStack(spacing: 6) {
                        SetSymbolView(setCode: deck?.code ?? summary?.code ?? "", size: 16, tint: .secondary)
                        Text((deck?.code ?? summary?.code ?? "").uppercased())
                    }
                }
                if let date = SetBrowsing.releaseDate(deck?.releaseDate ?? summary?.releaseDate) {
                    LabeledContent("Released", value: date)
                }
                LabeledContent("Format", value: snapshot.format.label)
            }
            Section {
                LabeledContent("Cards", value: "\(snapshot.mainCopies)")
                if !snapshot.sideboard.isEmpty {
                    LabeledContent("Sideboard", value: "\(snapshot.sideboard.reduce(0) { $0 + $1.quantity })")
                }
                if showsPrices {
                    LabeledContent("Market value", value: PriceFormat.string(snapshot.stats.totalValue))
                }
                LabeledContent("In your collection", value: "\(ownedCopies) of \(snapshot.mainCopies)")
                    .accessibilityIdentifier("precon-owned")
                LabeledContent("Missing", value: "\(missing)")
            } header: {
                Text("What's In It")
            } footer: {
                Text("Copies the collection holds in any printing count as in it. Import the deck to build it from them.")
            }
            if !unresolved.isEmpty {
                Section("Not in the Catalog") {
                    ForEach(unresolved, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
            if let source = deck?.source, let url = URL(string: source) {
                Section {
                    Link(destination: url) { Label("Where this list came from", systemImage: "safari") }
                }
            }
            Section {
                Text("Preconstructed deck lists come from MTGJSON.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
