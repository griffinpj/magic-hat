//
//  DecksView.swift
//  magic-hat
//
//  The Decks tab: a grid of deck tiles (cover art, format, colour identity,
//  built progress) read from DeckStore off the main actor, and one "+" menu
//  to start a deck three ways — from scratch, from a list file, or by
//  pasting a list (deck sites copy lists to the clipboard). The paste
//  happens in the sheet through a PasteButton: reading the pasteboard
//  directly raises iOS's "Allow Paste" prompt and blocks the app under it.
//  A new deck opens itself.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DecksView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var decks: [DeckSummary] = []
    @State private var hasLoaded = false
    @State private var path: [UUID] = []
    @State private var showNewDeck = false
    @State private var showFileImporter = false
    @State private var importSource: DeckImportSource?
    @State private var importError: String?
    @State private var search = ""

    private var deckTracker: DeckChangeTracker { .shared }
    private var collectionTracker: CollectionChangeTracker { .shared }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var shown: [DeckSummary] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return decks }
        return decks.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.format.label.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Decks")
                .searchable(text: $search, prompt: "Search decks")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { addMenu }
                }
                .navigationDestination(for: UUID.self) { DeckDetailView(deckID: $0) }
                .sheet(isPresented: $showNewDeck) {
                    NewDeckView { id in path.append(id) }
                }
                .sheet(item: $importSource) { source in
                    DeckImportView(source: source) { id in path.append(id) }
                }
                .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.plainText, .text, .utf8PlainText]) { result in
                    importFile(result)
                }
                .alert("Couldn't Read File", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(importError ?? "")
                }
                .task(id: "\(deckTracker.revision)|\(collectionTracker.revision)") { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        if !hasLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if decks.isEmpty {
            ContentUnavailableView {
                Label("No Decks", systemImage: "rectangle.stack")
            } description: {
                Text("Build a deck from your collection, or import a list from any deck site.")
            } actions: {
                Button("New Deck", systemImage: "plus") { showNewDeck = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("decks-empty-new")
                Button("Paste a Deck List…", systemImage: "doc.on.clipboard") { importClipboard() }
                    .accessibilityIdentifier("decks-empty-clipboard")
                Button("Import from File…", systemImage: "doc") { showFileImporter = true }
                    .accessibilityIdentifier("decks-empty-file")
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(shown) { deck in
                        NavigationLink(value: deck.id) {
                            DeckTile(deck: deck)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("New Deck…", systemImage: "plus") { showNewDeck = true }
                .accessibilityIdentifier("decks-menu-new")
            Divider()
            Button("Paste a Deck List…", systemImage: "doc.on.clipboard") { importClipboard() }
                .accessibilityIdentifier("decks-menu-clipboard")
            Button("Import from File…", systemImage: "doc") { showFileImporter = true }
                .accessibilityIdentifier("decks-menu-file")
        } label: {
            Label("Add Deck", systemImage: "plus")
        }
        .accessibilityIdentifier("decks-add")
    }

    // MARK: Actions

    private func load() async {
        let store = DeckStore.shared(for: modelContext.container)
        if let fetched = try? await store.overview(), !Task.isCancelled {
            decks = fetched
        }
        hasLoaded = true
    }

    private func importClipboard() {
        importSource = DeckImportSource(text: "", suggestedName: nil)
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                importSource = DeckImportSource(text: text, suggestedName: url.deletingPathExtension().lastPathComponent)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

// MARK: - Tile

struct DeckTile: View {
    let deck: DeckSummary

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CardArtImage(urlString: deck.coverArtURL)
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(deck.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    if deck.isLocked {
                        Image(systemName: "lock.fill").font(.caption2)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        ForEach(deck.identity, id: \.self) { color in
                            ManaSymbolView(symbol: ManaSymbol(color.rawValue), size: 16)
                        }
                    }
                }
                if deck.mainCopies > 0 {
                    ProgressView(value: Double(deck.builtCopies), total: Double(deck.mainCopies))
                        .tint(deck.builtCopies == deck.mainCopies ? .green : .white)
                        .accessibilityLabel("Built \(deck.builtCopies) of \(deck.mainCopies)")
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deck-tile-\(deck.name)")
    }

    private var subtitle: String {
        if let target = deck.format.cardTarget { return "\(deck.format.label) · \(deck.mainCopies)/\(target)" }
        return "\(deck.format.label) · \(deck.mainCopies) cards"
    }
}

/// What the import sheet starts from.
struct DeckImportSource: Identifiable {
    let id = UUID()
    let text: String
    let suggestedName: String?
}
