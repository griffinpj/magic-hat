//
//  DeckDetailView.swift
//  magic-hat
//
//  One deck: title and subtitle in the bar, a segmented picker for Cards /
//  Stats / Details, and a "…" menu for the things done to a deck as a whole
//  (build, disassemble, lock, rename, export, delete). Everything shown
//  comes from one DeckSnapshot read off-main, refetched when a deck or
//  collection write bumps its tracker.
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
    @State private var confirmDisassemble = false
    @State private var confirmDelete = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var error: String?
    /// Reported by the Cards tab; the picker steps aside for the search.
    @State private var searchActive = false

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
                VStack(spacing: 0) {
                    if !(tab == .cards && searchActive) {
                        Picker("Section", selection: $tab) {
                            ForEach(Tab.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("deck-tabs")
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    switch tab {
                    case .cards:
                        DeckCardsView(snapshot: snapshot, searchActive: $searchActive)
                    case .stats:
                        DeckStatsView(snapshot: snapshot)
                    case .details:
                        DeckDetailsView(snapshot: snapshot, onBuild: { showBuild = true },
                                        onDisassemble: { confirmDisassemble = true },
                                        onDelete: { confirmDelete = true })
                    }
                }
            } else if hasLoaded {
                ContentUnavailableView("Deck Not Found", systemImage: "rectangle.stack")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(snapshot?.name ?? "Deck")
        .navigationSubtitle(snapshot?.subtitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .sheet(isPresented: $showBuild) {
            if let snapshot { DeckBuildSheet(deckID: snapshot.id, deckName: snapshot.name) }
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
                Button("Build Deck…", systemImage: "hammer") { showBuild = true }
                    .disabled(snapshot.mainCopies == 0)
                Button("Disassemble Deck…", systemImage: "arrow.uturn.backward") { confirmDisassemble = true }
                    .disabled(!snapshot.isBuilt)
                Divider()
                Button("Rename…", systemImage: "pencil") {
                    newName = snapshot.name
                    showRename = true
                }
                ShareLink(item: DeckListParser.export(snapshot), subject: Text(snapshot.name),
                          preview: SharePreview(snapshot.name)) {
                    Label("Export List", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button("Delete Deck", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("deck-menu")
    }

    // MARK: Actions

    private func load() async {
        let store = DeckStore.shared(for: modelContext.container)
        if let fetched = try? await store.snapshot(deckID: deckID), !Task.isCancelled {
            snapshot = fetched
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
