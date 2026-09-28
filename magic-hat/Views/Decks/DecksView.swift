//
//  DecksView.swift
//  magic-hat
//
//  The Decks tab, organised the way the Files app is: folders that hold
//  decks and more folders, shown as icons (the deck tiles, with folders as
//  tiles of their own) or as a list, sorted by name, date or format, with
//  folders first. A folder pushes the same browser one level down; the
//  back button is the way up. Decks and folders move by drag and drop onto
//  a folder, or with Move from their context menu (a destination sheet
//  like Files' Move). Searching looks through every folder at once.
//
//  One "+" menu starts a deck three ways — from scratch, from a list file,
//  or by pasting a list (deck sites copy lists to the clipboard) — or makes
//  a folder; a new deck lands in the folder being shown and opens itself.
//  The paste happens in the sheet through a PasteButton: reading the
//  pasteboard directly raises iOS's "Allow Paste" prompt and blocks the
//  app under it.
//
//  Summaries come from DeckStore off the main actor; the folders are a
//  small table read with @Query.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// What the Decks tab's stack pushes.
enum DeckRoute: Hashable {
    case deck(UUID)
    case folder(UUID)
}

struct DecksView: View {
    @State private var path: [DeckRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            DeckBrowser(folderID: nil) { path.append($0) }
                .navigationDestination(for: DeckRoute.self) { route in
                    switch route {
                    case .deck(let id): DeckDetailView(deckID: id)
                    case .folder(let id): DeckBrowser(folderID: id) { path.append($0) }
                    }
                }
        }
    }
}

nonisolated enum DeckBrowserLayout: String, CaseIterable {
    case icons, list
}

nonisolated enum DeckBrowserSort: String, CaseIterable, Identifiable {
    case name, updated, created, format

    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .updated: return "Date Modified"
        case .created: return "Date Created"
        case .format: return "Format"
        }
    }

    func sorted(_ decks: [DeckSummary]) -> [DeckSummary] {
        decks.sorted { a, b in
            switch self {
            case .name: break
            case .updated: if a.updatedDate != b.updatedDate { return a.updatedDate > b.updatedDate }
            case .created: if a.createdDate != b.createdDate { return a.createdDate > b.createdDate }
            case .format: if a.format != b.format { return a.format.label < b.format.label }
            }
            let order = a.name.localizedStandardCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }
}

/// One folder's contents (nil: the top level).
struct DeckBrowser: View {
    let folderID: UUID?
    let open: (DeckRoute) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DeckFolder.name) private var folders: [DeckFolder]

    @State private var decks: [DeckSummary] = []
    @State private var hasLoaded = false
    @State private var showNewDeck = false
    @State private var showFileImporter = false
    @State private var importSource: DeckImportSource?
    @State private var importError: String?
    @State private var search = ""
    @State private var moving: MoveRequest?
    @State private var renaming: RenameRequest?
    @State private var renameText = ""
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var pendingDelete: DeleteRequest?
    @State private var error: String?
    @State private var dropTarget: UUID?
    @State private var showGuide = false
    /// Choosing decks to move or delete together, as in Files' Select.
    @State private var selecting = false
    @State private var chosen: Set<UUID> = []
    @State private var confirmDeleteChosen = false

    @AppStorage("decks.layout") private var layoutRaw = DeckBrowserLayout.icons.rawValue
    @AppStorage("decks.sort") private var sortRaw = DeckBrowserSort.updated.rawValue
    private var layout: DeckBrowserLayout { DeckBrowserLayout(rawValue: layoutRaw) ?? .icons }
    private var sort: DeckBrowserSort { DeckBrowserSort(rawValue: sortRaw) ?? .updated }

    private var deckTracker: DeckChangeTracker { .shared }
    private var collectionTracker: CollectionChangeTracker { .shared }

    private var tree: DeckFolderTree { DeckFolderTree(folders) }
    private var folder: DeckFolder? { folders.first { $0.id == folderID } }
    private var title: String { folderID == nil ? "Decks" : (folder?.name ?? "Folder") }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }
    private var isSearching: Bool { !query.isEmpty }

    /// Subfolders here; none while searching (search is flat, like Files').
    private var shownFolders: [DeckFolderTree.Node] {
        isSearching ? [] : tree.children(of: folderID)
    }

    private var shownDecks: [DeckSummary] {
        if isSearching {
            return sort.sorted(decks.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.format.label.localizedCaseInsensitiveContains(query)
            })
        }
        return sort.sorted(decks.filter { $0.folderID == folderID })
    }

    struct MoveRequest: Identifiable {
        let deckIDs: [UUID]
        let folderID: UUID?
        let name: String
        var id: String { (deckIDs.map(\.uuidString) + [folderID?.uuidString ?? ""]).joined() }
    }

    struct RenameRequest: Identifiable {
        let deckID: UUID?
        let folderID: UUID?
        var id: String { deckID?.uuidString ?? folderID?.uuidString ?? "" }
    }

    struct DeleteRequest: Identifiable {
        let deck: DeckSummary?
        let folder: DeckFolderTree.Node?
        var id: String { deck?.id.uuidString ?? folder?.id.uuidString ?? "" }
    }

    var body: some View {
        content
            .navigationTitle(title)
            // A subfolder is pushed: inline, as every pushed screen is.
            .navigationBarTitleDisplayMode(folderID == nil ? .automatic : .inline)
            // Always shown, as on every other screen: with the automatic
            // drawer a pushed folder's list started under the hidden field
            // and the field slid over the first row.
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: folderID == nil ? "Search decks" : "Search all decks")
            .toolbar {
                if selecting {
                    selectionToolbar
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        if folderID == nil {
                            Button("Managing Decks", systemImage: "info.circle") { showGuide = true }
                                .accessibilityIdentifier("decks-info")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        viewMenu
                        addMenu
                    }
                }
            }
            .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
            .navigationBarBackButtonHidden(selecting)
            .sheet(isPresented: $showGuide) { DecksGuideView() }
            .confirmationDialog(chosen.count == 1 ? "Delete 1 Deck?" : "Delete \(chosen.count) Decks?",
                                isPresented: $confirmDeleteChosen, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteChosen() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Built decks go back to their collections first. No cards are lost.")
            }
            .sheet(isPresented: $showNewDeck) {
                NewDeckView { id in file(id) }
            }
            .sheet(item: $importSource) { source in
                DeckImportView(source: source) { id in file(id) }
            }
            .sheet(item: $moving, onDismiss: {
                if selecting { selecting = false; chosen = [] }
            }) { request in
                DeckMoveSheet(request: request, tree: tree)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.plainText, .text, .utf8PlainText]) { result in
                importFile(result)
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                    .textInputAutocapitalization(.words)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { request in
                TextField("Name", text: $renameText)
                Button("Save") { rename(request) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { request in
                Button(request.folder != nil ? "Delete Folder" : "Delete Deck", role: .destructive) { delete(request) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                if request.folder != nil {
                    Text("Its decks and folders move up a level. No deck is deleted.")
                } else if let deck = request.deck, deck.builtCopies > 0 {
                    Text("Its cards go back to their collections first, then the list is deleted.")
                } else {
                    Text("The list is deleted. No cards are affected.")
                }
            }
            .alert("Couldn't Read File", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .alert("Something Went Wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .task(id: "\(deckTracker.revision)|\(collectionTracker.revision)") { await load() }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if !hasLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if decks.isEmpty && folders.isEmpty {
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
        } else if isSearching && shownDecks.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if shownFolders.isEmpty && shownDecks.isEmpty {
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder")
            } description: {
                Text("Drag decks here, or use Move from a deck's menu.")
            } actions: {
                Button("New Deck", systemImage: "plus") { showNewDeck = true }
            }
        } else if layout == .icons {
            iconGrid
        } else {
            list
        }
    }

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(shownFolders) { node in
                    Button { open(.folder(node.id)) } label: {
                        FolderTile(name: node.name, covers: covers(in: node.id), count: itemCount(in: node.id),
                                   isDropTarget: dropTarget == node.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { folderMenu(node) }
                    .draggable(DeckDragItem.folder(node.id).payload)
                    .dropDestination(for: String.self) { items, _ in drop(items, into: node.id) } isTargeted: { over in
                        dropTarget = over ? node.id : (dropTarget == node.id ? nil : dropTarget)
                    }
                    .accessibilityIdentifier("deck-folder-\(node.name)")
                }
                ForEach(shownDecks) { deck in
                    Button { tapDeck(deck) } label: {
                        DeckTile(deck: deck, location: isSearching ? location(of: deck) : nil)
                            .overlay(alignment: .topTrailing) {
                                if selecting { SelectionMark(isSelected: chosen.contains(deck.id)).padding(8) }
                            }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { if !selecting { deckMenu(deck) } }
                    .draggable(DeckDragItem.deck(deck.id).payload)
                    .accessibilityAddTraits(chosen.contains(deck.id) ? .isSelected : [])
                }
            }
            .padding(16)
        }
    }

    private var list: some View {
        List {
            ForEach(shownFolders) { node in
                Button { open(.folder(node.id)) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 56, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name).foregroundStyle(.primary)
                            Text(countLine(itemCount(in: node.id))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(dropTarget == node.id ? Color.accentColor.opacity(0.15) : nil)
                .contextMenu { folderMenu(node) }
                .draggable(DeckDragItem.folder(node.id).payload)
                .dropDestination(for: String.self) { items, _ in drop(items, into: node.id) } isTargeted: { over in
                    dropTarget = over ? node.id : (dropTarget == node.id ? nil : dropTarget)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        pendingDelete = DeleteRequest(deck: nil, folder: node)
                    }
                    Button("Move", systemImage: "folder") {
                        moving = MoveRequest(deckIDs: [], folderID: node.id, name: node.name)
                    }
                    .tint(.blue)
                }
                .accessibilityIdentifier("deck-folder-\(node.name)")
            }
            ForEach(shownDecks) { deck in
                Button { tapDeck(deck) } label: {
                    HStack(spacing: 12) {
                        if selecting { SelectionMark(isSelected: chosen.contains(deck.id), size: 22) }
                        CardArtThumb(artURL: deck.coverArtURL)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(deck.name).foregroundStyle(.primary).lineLimit(1)
                                if deck.isLocked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text(isSearching ? "\(DeckTile.subtitle(deck)) · \(location(of: deck))" : DeckTile.subtitle(deck))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 2) {
                            ForEach(deck.identity, id: \.self) { color in
                                ManaSymbolView(symbol: ManaSymbol(color.rawValue), size: 14)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { if !selecting { deckMenu(deck) } }
                .draggable(DeckDragItem.deck(deck.id).payload)
                // Files' row swipes: the two things done to a deck most.
                .swipeActions(edge: .trailing) {
                    if !selecting {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            pendingDelete = DeleteRequest(deck: deck, folder: nil)
                        }
                        Button("Move", systemImage: "folder") {
                            moving = MoveRequest(deckIDs: [deck.id], folderID: nil, name: deck.name)
                        }
                        .tint(.blue)
                    }
                }
                .accessibilityIdentifier("deck-tile-\(deck.name)")
            }
        }
        .listStyle(.plain)
    }

    // MARK: Menus

    private var viewMenu: some View {
        Menu {
            Picker("View", selection: $layoutRaw) {
                Label("Icons", systemImage: "square.grid.2x2").tag(DeckBrowserLayout.icons.rawValue)
                Label("List", systemImage: "list.bullet").tag(DeckBrowserLayout.list.rawValue)
            }
            .pickerStyle(.inline)
            Picker("Sort By", selection: $sortRaw) {
                ForEach(DeckBrowserSort.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Select Decks", systemImage: "checkmark.circle") {
                chosen = []
                selecting = true
            }
            .disabled(shownDecks.isEmpty)
            .accessibilityIdentifier("decks-select")
            if let folderID, let node = tree.nodes[folderID] {
                Divider()
                Button("Rename Folder…", systemImage: "pencil") { startRename(folder: node) }
                Button("Move Folder…", systemImage: "folder") {
                    moving = MoveRequest(deckIDs: [], folderID: node.id, name: node.name)
                }
            }
        } label: {
            Label("View Options", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("decks-view-menu")
    }

    private var addMenu: some View {
        Menu {
            Button("New Deck…", systemImage: "plus") { showNewDeck = true }
                .accessibilityIdentifier("decks-menu-new")
            Button("New Folder…", systemImage: "folder.badge.plus") {
                newFolderName = ""
                showNewFolder = true
            }
            .accessibilityIdentifier("decks-menu-folder")
            Divider()
            Button("Paste a Deck List…", systemImage: "doc.on.clipboard") { importClipboard() }
                .accessibilityIdentifier("decks-menu-clipboard")
            Button("Import from Link…", systemImage: "link") {
                importSource = DeckImportSource(text: "", suggestedName: nil, focusesLink: true)
            }
            .accessibilityIdentifier("decks-menu-link")
            Button("Import from File…", systemImage: "doc") { showFileImporter = true }
                .accessibilityIdentifier("decks-menu-file")
        } label: {
            Label("Add Deck", systemImage: "plus")
        }
        .accessibilityIdentifier("decks-add")
    }

    @ViewBuilder private func deckMenu(_ deck: DeckSummary) -> some View {
        Button("Open", systemImage: "rectangle.stack") { open(.deck(deck.id)) }
        Button("Move…", systemImage: "folder") {
            moving = MoveRequest(deckIDs: [deck.id], folderID: nil, name: deck.name)
        }
        Button("Rename…", systemImage: "pencil") {
            renameText = deck.name
            renaming = RenameRequest(deckID: deck.id, folderID: nil)
        }
        Divider()
        Button("Delete Deck", systemImage: "trash", role: .destructive) {
            pendingDelete = DeleteRequest(deck: deck, folder: nil)
        }
    }

    @ViewBuilder private func folderMenu(_ node: DeckFolderTree.Node) -> some View {
        Button("Open", systemImage: "folder") { open(.folder(node.id)) }
        Button("Move…", systemImage: "folder") {
            moving = MoveRequest(deckIDs: [], folderID: node.id, name: node.name)
        }
        Button("Rename…", systemImage: "pencil") { startRename(folder: node) }
        Divider()
        Button("Delete Folder", systemImage: "trash", role: .destructive) {
            pendingDelete = DeleteRequest(deck: nil, folder: node)
        }
    }

    @ToolbarContentBuilder private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            let all = !shownDecks.isEmpty && chosen.count == shownDecks.count
            Button(all ? "Deselect All" : "Select All") {
                chosen = all ? [] : Set(shownDecks.map(\.id))
            }
        }
        ToolbarItem(placement: .principal) {
            Text(chosen.isEmpty ? "Select Decks" : (chosen.count == 1 ? "1 Deck" : "\(chosen.count) Decks"))
                .font(.headline)
                .accessibilityIdentifier("decks-selection-count")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { selecting = false; chosen = [] }
                .accessibilityIdentifier("decks-selection-done")
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Move", systemImage: "folder") {
                let names = decks.filter { chosen.contains($0.id) }.map(\.name)
                moving = MoveRequest(deckIDs: Array(chosen), folderID: nil,
                                     name: names.count == 1 ? names[0] : "\(names.count) Decks")
            }
            .disabled(chosen.isEmpty)
            .accessibilityIdentifier("decks-selection-move")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Delete", systemImage: "trash") { confirmDeleteChosen = true }
                .disabled(chosen.isEmpty)
                .accessibilityIdentifier("decks-selection-delete")
        }
    }

    private func tapDeck(_ deck: DeckSummary) {
        if selecting {
            if chosen.contains(deck.id) { chosen.remove(deck.id) } else { chosen.insert(deck.id) }
        } else {
            open(.deck(deck.id))
        }
    }

    private func deleteChosen() {
        let chosenDecks = decks.filter { chosen.contains($0.id) }
        let container = modelContext.container
        let context = modelContext
        Task {
            do {
                for deck in chosenDecks {
                    if deck.builtCopies > 0 {
                        _ = try await DeckBuilder.shared(for: container).disassemble(deckID: deck.id)
                        CollectionChangeTracker.shared.bump()
                    }
                    try DeckEditController.delete(deckID: deck.id, context: context)
                }
                selecting = false
                chosen = []
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var deleteTitle: String {
        if let folder = pendingDelete?.folder { return "Delete “\(folder.name)”?" }
        return "Delete “\(pendingDelete?.deck?.name ?? "deck")”?"
    }

    // MARK: Folder details

    /// Covers of the decks directly in a folder, for its tile.
    private func covers(in folder: UUID) -> [String] {
        Array(sort.sorted(decks.filter { $0.folderID == folder }).compactMap(\.coverArtURL).prefix(3))
    }

    private func itemCount(in folder: UUID) -> (decks: Int, folders: Int) {
        (decks.filter { $0.folderID == folder }.count, tree.children(of: folder).count)
    }

    private func countLine(_ count: (decks: Int, folders: Int)) -> String {
        FolderTile.countLine(count)
    }

    /// "in Commander / Mono Red", for search results.
    private func location(of deck: DeckSummary) -> String {
        let path = tree.path(to: deck.folderID).map(\.name)
        return path.isEmpty ? "Decks" : path.joined(separator: " / ")
    }

    // MARK: Actions

    private func load() async {
        let store = DeckStore.shared(for: modelContext.container)
        if let fetched = try? await store.overview(), !Task.isCancelled {
            decks = fetched
        }
        hasLoaded = true
    }

    /// A deck made here lands in this folder, then opens.
    private func file(_ id: UUID) {
        if let folderID {
            try? DeckEditController.moveDecks([id], to: folderID, context: modelContext)
        }
        open(.deck(id))
    }

    private func createFolder() {
        attempt { try DeckEditController.createFolder(named: newFolderName, in: folderID, context: modelContext) }
    }

    private func startRename(folder node: DeckFolderTree.Node) {
        renameText = node.name
        renaming = RenameRequest(deckID: nil, folderID: node.id)
    }

    private func rename(_ request: RenameRequest) {
        if let id = request.deckID {
            attempt { try DeckEditController.rename(deckID: id, to: renameText, context: modelContext) }
        } else if let id = request.folderID {
            attempt { try DeckEditController.renameFolder(id, to: renameText, context: modelContext) }
        }
    }

    private func delete(_ request: DeleteRequest) {
        if let node = request.folder {
            attempt { try DeckEditController.deleteFolder(node.id, context: modelContext) }
        } else if let deck = request.deck {
            let container = modelContext.container
            let context = modelContext
            Task {
                do {
                    if deck.builtCopies > 0 {
                        _ = try await DeckBuilder.shared(for: container).disassemble(deckID: deck.id)
                        CollectionChangeTracker.shared.bump()
                    }
                    try DeckEditController.delete(deckID: deck.id, context: context)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    /// A deck or folder dropped on a folder tile.
    private func drop(_ payloads: [String], into target: UUID) -> Bool {
        dropTarget = nil
        let items = payloads.compactMap(DeckDragItem.init(payload:))
        guard !items.isEmpty else { return false }
        attempt {
            let deckIDs = items.compactMap { if case .deck(let id) = $0 { id } else { nil } }
            if !deckIDs.isEmpty { try DeckEditController.moveDecks(deckIDs, to: target, context: modelContext) }
            for case .folder(let id) in items where id != target {
                try DeckEditController.moveFolder(id, to: target, context: modelContext)
            }
        }
        return true
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { self.error = error.localizedDescription }
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

/// A dragged deck or folder, as the plain string SwiftUI's drag and drop
/// carries ("deck:<uuid>", "folder:<uuid>").
nonisolated enum DeckDragItem: Hashable {
    case deck(UUID)
    case folder(UUID)

    var payload: String {
        switch self {
        case .deck(let id): return "magichat-deck:\(id.uuidString)"
        case .folder(let id): return "magichat-folder:\(id.uuidString)"
        }
    }

    init?(payload: String) {
        let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "magichat-deck": self = .deck(id)
        case "magichat-folder": self = .folder(id)
        default: return nil
        }
    }
}

// MARK: - Move

/// Files' Move sheet: the folder tree, indented, with the top level first;
/// the current place is checked and a folder can't be moved into itself.
private struct DeckMoveSheet: View {
    let request: DeckBrowser.MoveRequest
    let tree: DeckFolderTree

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Deck.name) private var allDecks: [Deck]
    @State private var error: String?
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    /// Where the thing being moved is now.
    private var current: UUID? {
        if let folder = request.folderID { return tree.nodes[folder]?.parentID }
        let id = request.deckIDs.first
        return allDecks.first { $0.id == id }?.folderID
    }

    var body: some View {
        NavigationStack {
            List {
                destination(nil, name: "Decks", depth: 0)
                ForEach(tree.flattened(), id: \.node.id) { entry in
                    destination(entry.node.id, name: entry.node.name, depth: entry.depth + 1)
                }
            }
            .navigationTitle("Move “\(request.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        showNewFolder = true
                    }
                }
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create and Move") { createAndMove() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't Move", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .presentationDetents([.medium, .large])
    }

    private func destination(_ id: UUID?, name: String, depth: Int) -> some View {
        let blocked = request.folderID.map { tree.isInside(id, $0) } ?? false
        return Button {
            move(to: id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: id == nil ? "rectangle.stack.fill" : "folder.fill")
                    .foregroundStyle(blocked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                Text(name).foregroundStyle(blocked ? .secondary : .primary)
                Spacer()
                if id == current { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(.leading, CGFloat(depth) * 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .accessibilityIdentifier("move-to-\(name)")
    }

    private func move(to id: UUID?) {
        do {
            if let folder = request.folderID {
                try DeckEditController.moveFolder(folder, to: id, context: modelContext)
            } else {
                try DeckEditController.moveDecks(request.deckIDs, to: id, context: modelContext)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createAndMove() {
        do {
            let folder = try DeckEditController.createFolder(named: newFolderName, in: nil, context: modelContext)
            move(to: folder.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Tiles

/// A folder among the deck tiles: the same size, glass, with the covers of
/// the decks inside fanned under a folder mark, and what it holds.
struct FolderTile: View {
    let name: String
    let covers: [String]
    let count: (decks: Int, folders: Int)
    var isDropTarget = false

    static func countLine(_ count: (decks: Int, folders: Int)) -> String {
        var parts: [String] = []
        if count.folders > 0 { parts.append(count.folders == 1 ? "1 folder" : "\(count.folders) folders") }
        parts.append(count.decks == 1 ? "1 deck" : "\(count.decks) decks")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                HStack(spacing: -18) {
                    ForEach(Array(covers.enumerated()), id: \.offset) { index, url in
                        CardArtThumb(artURL: url, width: 60, height: 44, cornerRadius: 7)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                            .rotationEffect(.degrees(Double(index - 1) * 4))
                            .zIndex(Double(-index))
                    }
                }
                .padding(.leading, 34)
                .padding(.bottom, 6)
                Image(systemName: "folder.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text(name)
                .font(.headline)
                .lineLimit(2)
            Text(Self.countLine(count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(height: 160)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(isDropTarget ? .regular.tint(.accentColor.opacity(0.3)) : .regular,
                     in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(isDropTarget ? 1.04 : 1)
        .animation(.snappy, value: isDropTarget)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), folder, \(Self.countLine(count))")
    }
}

struct DeckTile: View {
    let deck: DeckSummary
    /// The folder path, shown on search results that span folders.
    var location: String? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CardArtImage(urlString: deck.coverArtURL)
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                }
            VStack(alignment: .leading, spacing: 4) {
                if let location {
                    Label(location, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                Text(deck.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(Self.subtitle(deck))
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

    static func subtitle(_ deck: DeckSummary) -> String {
        if let target = deck.format.cardTarget { return "\(deck.format.label) · \(deck.mainCopies)/\(target)" }
        return "\(deck.format.label) · \(deck.mainCopies) cards"
    }
}

/// What the import sheet starts from.
struct DeckImportSource: Identifiable {
    let id = UUID()
    let text: String
    let suggestedName: String?
    /// Opened from "Import from Link…": the link field has the focus.
    var focusesLink = false
}
