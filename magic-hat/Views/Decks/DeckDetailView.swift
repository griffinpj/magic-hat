//
//  DeckDetailView.swift
//  magic-hat
//
//  One deck: title and subtitle in the bar, a segmented picker for Cards /
//  Stats / Details, a "+" that opens the add-cards sheet, and a "…" menu
//  for the things done to a deck as a whole (build, disassemble, lock,
//  rename, export, delete). Everything shown comes from one DeckSnapshot
//  read off-main, refetched when a deck or collection write bumps its
//  tracker.
//
//  The search field belongs to the whole screen, not the Cards tab: a
//  field that came and went with the tab moved the picker up and down on
//  every switch. Searching is a Cards thing, so activating the field
//  switches to Cards. While the search session is active the Back button
//  steps aside — the field's own X ends the session and brings it back —
//  so Back never pops the deck out from under a search. Two trailing
//  items, no more: with three the inline title goes leading-aligned and
//  slides when Back hides. The filter sheet lives in the add sheet.
//
//  The three sections are pages of a paged TabView, so a horizontal swipe
//  moves between them as the segmented picker does. The picker sits in a
//  top `safeAreaBar` rather than above the pages as a plain view: it is
//  part of the bar region with the navigation bar and the search field,
//  the lists scroll beneath it with the same scroll-edge effect, and a
//  pinned section header pins under it instead of under the search field.
//

import SwiftUI
import SwiftData

struct DeckDetailView: View {
    let deckID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: DeckSnapshot?
    @State private var hasLoaded = false
    @State private var tab: Tab = .cards
    @State private var showBuild = false
    /// The card viewer, presented from the screen rather than from the
    /// Cards page: a cover on a page of the paged TabView stopped
    /// presenting after a sheet had been shown while another page was
    /// selected, and only re-selecting the page brought it back. The zoom
    /// transition's namespace lives here with it; the page marks its rows.
    @State private var viewer: CardViewerSession?
    @Namespace private var zoom
    /// The deck as a target for the viewer opened from a row: its bar
    /// steps the card's copies on the mainboard, and the Synergies screen
    /// pushed from it can add. Made on the first load (it needs the
    /// context) and refreshed from every snapshot.
    @State private var session: DeckAddSession?
    /// The add sheet, presented with its scope *in the item*: the deck
    /// screen has a search session, and a presentation closure that read
    /// the scope from another @State saw the initial value (see
    /// CardViewerSession for the same lesson).
    @State private var addSheet: AddSheet?

    struct AddSheet: Identifiable {
        let scope: DeckSearchScope
        var id: String { scope.rawValue }
    }
    @State private var showExport = false
    @State private var filterText = ""
    @State private var searchSessionActive = false
    @State private var confirmDisassemble = false
    @State private var confirmDelete = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var error: String?
    /// Analysis and Swaps, pushed from the "…" menu and the Cards tab's
    /// swaps row (Stats has its own rows for them).
    @State private var pushed: Push?
    enum Push: String, Identifiable {
        case analysis, swaps
        var id: String { rawValue }
    }

    /// One per deck for the app's life, so leaving and returning keeps
    /// what was read and fetched.
    private var analysis: DeckAnalysisController { .shared(for: deckID) }

    private var deckTracker: DeckChangeTracker { .shared }
    private var collectionTracker: CollectionChangeTracker { .shared }

    enum Tab: String, CaseIterable, Identifiable {
        case cards, stats, details
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var systemImage: String {
            switch self {
            case .cards: return "rectangle.stack"
            case .stats: return "chart.bar"
            case .details: return "info.circle"
            }
        }
    }

    var body: some View {
        Group {
            if let snapshot {
                TabView(selection: $tab) {
                    DeckCardsView(snapshot: snapshot, filterText: filterText, onAddCards: { openAdd(.all) },
                                  onShowIssues: { withAnimation { tab = .stats } },
                                  analysis: analysis, onShowSwaps: { pushed = .swaps },
                                  zoom: zoom, viewer: viewer, session: session, onOpenViewer: { viewer = $0 })
                        .tag(Tab.cards)
                    DeckStatsView(snapshot: snapshot, analysis: analysis, onAddRecommended: { openAdd(.recommended) })
                        .tag(Tab.stats)
                    DeckDetailsView(snapshot: snapshot, onBuild: { showBuild = true },
                                    onDisassemble: { confirmDisassemble = true },
                                    onExport: { showExport = true },
                                    onDelete: { confirmDelete = true })
                        .tag(Tab.details)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // The bars show whatever is behind them, and behind a
                // grouped list that is the grouped grey — as on any Settings
                // screen — while the plain card list is white. The page
                // container paints it, since the pages themselves stop at
                // the bar.
                .background(tab == .cards ? Color(.systemBackground) : Color(.systemGroupedBackground),
                            ignoresSafeAreaEdges: .all)
                .animation(.default, value: tab)
                .safeAreaBar(edge: .top) {
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("deck-tabs")
                }
            } else if hasLoaded {
                ContentUnavailableView("Deck Not Found", systemImage: "rectangle.stack")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            SearchDismisser(isEmpty: filterText.isEmpty)
            SearchSessionReporter(isActive: $searchSessionActive)
        }
        .navigationTitle(snapshot?.name ?? "Deck")
        .navigationSubtitle(snapshot?.subtitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filterText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search this deck")
        // + and … stay reachable while typing; only Back steps aside.
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .navigationBarBackButtonHidden(searchSessionActive)
        .onChange(of: searchSessionActive) { _, active in if active { tab = .cards } }
        .onChange(of: filterText) { _, text in if !text.isEmpty { tab = .cards } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Add Cards", systemImage: "plus") { openAdd(.all) }
                    .disabled(snapshot?.isLocked ?? true)
                    .accessibilityIdentifier("deck-add-cards")
                menu
            }
        }
        .navigationDestination(item: $pushed) { push in
            if let snapshot {
                switch push {
                case .analysis: DeckAnalysisView(snapshot: snapshot, controller: analysis, onAddRecommended: { openAdd(.recommended) })
                case .swaps: DeckSwapsView(deckID: deckID, controller: analysis, context: modelContext)
                }
            }
        }
        .sheet(item: $addSheet) { sheet in
            DeckAddCardsView(deckID: deckID, context: modelContext, scope: sheet.scope)
        }
        .fullScreenCover(item: $viewer) { v in
            CardViewerView(items: v.items, currentID: Bindable(v).currentID, deck: v.deck)
                .navigationTransition(.zoom(sourceID: v.currentID ?? "", in: zoom))
        }
        .sheet(isPresented: $showBuild) {
            if let snapshot { DeckBuildSheet(deckID: snapshot.id, deckName: snapshot.name) }
        }
        .sheet(isPresented: $showExport) {
            if let snapshot { DeckExportView(snapshot: snapshot) }
        }
        .confirmationDialog("Disassemble \(snapshot?.name ?? "deck")?", isPresented: $confirmDisassemble, titleVisibility: .visible) {
            Button("Move \(snapshot?.builtCopies ?? 0) Cards Back", role: .destructive) { disassemble() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every card returns to the collection it was built from. The list stays.")
        }
        .confirmationDialog("Delete \(snapshot?.name ?? "deck")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Deck", role: .destructive) { deleteDeck() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(snapshot?.isBuilt == true
                 ? "Its cards go back to their collections first, then the list is deleted."
                 : "The list is deleted. No cards are affected.")
        }
        .alert("Rename Deck", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task(id: "\(deckID)|\(deckTracker.revision)|\(collectionTracker.revision)") { await load() }
    }

    private var menu: some View {
        Menu {
            if let snapshot {
                Button(snapshot.isLocked ? "Unlock Deck" : "Lock Deck",
                       systemImage: snapshot.isLocked ? "lock.open" : "lock") { toggleLock() }
                Divider()
                Button("Analyze Deck", systemImage: "chart.bar.xaxis") { pushed = .analysis }
                    .accessibilityIdentifier("deck-menu-analyze")
                Button("Recommended Cards", systemImage: "wand.and.stars") { openAdd(.recommended) }
                    .disabled(snapshot.isLocked)
                    .accessibilityIdentifier("deck-menu-recommend")
                Button("Suggested Swaps", systemImage: "arrow.left.arrow.right") { pushed = .swaps }
                    .accessibilityIdentifier("deck-menu-swaps")
                Divider()
                Button("Build Deck…", systemImage: "hammer") { showBuild = true }
                    .disabled(snapshot.mainCopies == 0)
                Button("Disassemble Deck…", systemImage: "arrow.uturn.backward") { confirmDisassemble = true }
                    .disabled(!snapshot.isBuilt)
                Divider()
                Button("Rename…", systemImage: "pencil") {
                    newName = snapshot.name
                    showRename = true
                }
                Button("Export…", systemImage: "square.and.arrow.up") { showExport = true }
                    .accessibilityIdentifier("deck-menu-export")
                Divider()
                Button("Delete Deck", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("deck-menu")
    }

    // MARK: Actions

    private func openAdd(_ scope: DeckSearchScope) {
        addSheet = AddSheet(scope: scope)
    }

    private func load() async {
        let store = DeckStore.shared(for: modelContext.container)
        if let fetched = try? await store.snapshot(deckID: deckID), !Task.isCancelled {
            snapshot = fetched
            if session == nil { session = DeckAddSession(deckID: deckID, board: .main, context: modelContext) }
            session?.update(from: fetched)
            analysis.refresh(snapshot: fetched, container: modelContext.container)
        } else if !Task.isCancelled {
            snapshot = nil
        }
        hasLoaded = true
    }

    private func toggleLock() {
        guard let snapshot else { return }
        do { try DeckEditController.setLocked(deckID: deckID, !snapshot.isLocked, context: modelContext) }
        catch { self.error = error.localizedDescription }
    }

    private func rename() {
        do { try DeckEditController.rename(deckID: deckID, to: newName, context: modelContext) }
        catch { self.error = error.localizedDescription }
    }

    private func disassemble() {
        let container = modelContext.container
        Task {
            do {
                _ = try await DeckBuilder.shared(for: container).disassemble(deckID: deckID)
                CollectionChangeTracker.shared.bump()
                DeckChangeTracker.shared.bump()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func deleteDeck() {
        let container = modelContext.container
        let context = modelContext
        Task {
            do {
                if snapshot?.isBuilt == true {
                    _ = try await DeckBuilder.shared(for: container).disassemble(deckID: deckID)
                    CollectionChangeTracker.shared.bump()
                }
                try DeckEditController.delete(deckID: deckID, context: context)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Relays whether the search session is active (readable only inside the
/// searchable content) to the screen, which hides Back for its duration.
private struct SearchSessionReporter: View {
    @Binding var isActive: Bool
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        Color.clear
            .onChange(of: isSearching, initial: true) { _, value in
                if isActive != value { isActive = value }
            }
    }
}
