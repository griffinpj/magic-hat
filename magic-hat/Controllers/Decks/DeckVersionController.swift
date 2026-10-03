//
//  DeckVersionController.swift
//  magic-hat
//
//  Writes for a deck's versions and branches (see DeckVersion for the
//  model): save, restore, discard, branch, switch, rename, delete. Small
//  and user-initiated — a list is a hundred rows — so on the main
//  context, like every other list edit, and like them they write nothing
//  to the History ledger: no copies move. Each ends with one save and one
//  DeckChangeTracker bump.
//
//  The rules that keep it safe:
//  - A branch only grows. Restore saves a *new* version holding the old
//    list; nothing is rewound, so nothing is orphaned.
//  - Unsaved changes are never lost by a switch or a restore: they are
//    saved first, as an automatic version on the branch being left.
//    Discard is the one thing that drops them, and it says so.
//  - New Branch carries unsaved changes along (git's `checkout -b`).
//  - Deleting a branch removes the versions only it reached.
//  - A built deck's cards follow its list. Changing the list of a deck
//    that is built — restore, switch, discard, a branch from an older
//    version — takes the deck apart first, changes the list, and builds
//    it again from the same collections (`changingList`): two History
//    actions, Disassembled and Built. Changing only the list left the
//    cards of the old list in the deck with no row to show them.
//

import Foundation
import SwiftData

@MainActor
enum DeckVersionController {
    enum VersionError: Error, LocalizedError {
        case deckMissing, versionMissing, branchMissing, emptyName, nameTaken, lastBranch, locked

        var errorDescription: String? {
            switch self {
            case .deckMissing: return "That deck no longer exists."
            case .versionMissing: return "That version no longer exists."
            case .branchMissing: return "That branch no longer exists."
            case .emptyName: return "Give the branch a name."
            case .nameTaken: return "This deck already has a branch with that name."
            case .lastBranch: return "A deck keeps at least one branch."
            case .locked: return "Unlock the deck to change its list."
            }
        }
    }

    /// Automatic versions kept per deck; older ones are folded away.
    static let automaticLimit = 20

    // MARK: Saving

    /// Saves the list as a version on the current branch. With
    /// `onlyIfChanged`, nothing is written when the list is what the
    /// branch's tip already holds (an automatic save with nothing to keep).
    @discardableResult
    static func save(deckID: UUID, name: String = "", kind: DeckVersion.Kind = .saved, note: String = "",
                     onlyIfChanged: Bool = false, context: ModelContext) throws -> DeckVersion? {
        let deck = try fetchDeck(deckID, context)
        let branch = try currentBranch(of: deck, context)
        let saved = try commit(deck: deck, branch: branch, name: name, kind: kind, note: note, onlyIfChanged: onlyIfChanged, context)
        try finish(deck, context)
        return saved
    }

    /// A version at a moment worth keeping (the deck was just built), only
    /// when versions are already in use on the deck and the list changed.
    static func autosaveIfTracking(deckID: UUID, note: String, context: ModelContext) {
        guard let deck = try? fetchDeck(deckID, context), deck.currentBranchID != nil else { return }
        _ = try? save(deckID: deckID, kind: .auto, note: note, onlyIfChanged: true, context: context)
    }

    /// `rows` is the list to save when it was just replaced in this same
    /// write: the relationship still lists rows deleted a line ago until
    /// the context saves.
    private static func commit(deck: Deck, branch: DeckBranch, name: String, kind: DeckVersion.Kind, note: String,
                               onlyIfChanged: Bool, rows given: [DeckVersionRow]? = nil, _ context: ModelContext) throws -> DeckVersion? {
        let rows = given ?? deck.cards.map(DeckVersionRow.init)
        let tip = try branch.tipVersionID.flatMap { try fetchVersion($0, context) }
        let tipRows = tip?.rows ?? []
        if onlyIfChanged, tip != nil, DeckVersionRow.sameList(tipRows, rows) { return nil }
        let diff = DeckListDiff.between(tipRows, rows)
        let version = DeckVersion(deckID: deck.id, parentID: tip?.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                  kind: kind, note: note, rows: rows, added: diff.added, removed: diff.removed)
        context.insert(version)
        branch.tipVersionID = version.id
        if kind == .auto { try prune(deckID: deck.id, context) }
        return version
    }

    // MARK: Restoring

    /// Puts an older version's list back, as a new version on the current
    /// branch. Unsaved changes are saved first.
    static func restore(versionID: UUID, context: ModelContext) throws {
        guard let version = try fetchVersion(versionID, context) else { throw VersionError.versionMissing }
        let deck = try fetchDeck(version.deckID, context)
        guard !deck.isLocked else { throw VersionError.locked }
        let branch = try currentBranch(of: deck, context)
        _ = try commit(deck: deck, branch: branch, name: "", kind: .auto, note: "Before restoring", onlyIfChanged: true, context)
        replaceList(of: deck, with: version.rows, context)
        _ = try commit(deck: deck, branch: branch, name: "", kind: .saved, note: "Restored “\(label(of: version))”",
                       onlyIfChanged: true, rows: version.rows, context)
        try finish(deck, context)
    }

    /// Drops the unsaved changes: the list goes back to the branch's tip.
    static func discardChanges(deckID: UUID, context: ModelContext) throws {
        let deck = try fetchDeck(deckID, context)
        guard !deck.isLocked else { throw VersionError.locked }
        let branch = try currentBranch(of: deck, context)
        guard let tip = try branch.tipVersionID.flatMap({ try fetchVersion($0, context) }) else { return }
        replaceList(of: deck, with: tip.rows, context)
        try finish(deck, context)
    }

    // MARK: Branches

    /// A new branch, switched to. From the list as it stands (unsaved
    /// changes come along, unsaved) or, with `versionID`, from that
    /// version — the list becomes that version's, and what was unsaved is
    /// kept on the branch being left.
    @discardableResult
    static func createBranch(deckID: UUID, name raw: String, from versionID: UUID? = nil, context: ModelContext) throws -> DeckBranch {
        let deck = try fetchDeck(deckID, context)
        let name = try validated(raw, deckID: deckID, except: nil, context)
        let current = try currentBranch(of: deck, context)
        let branch: DeckBranch
        if let versionID {
            guard let version = try fetchVersion(versionID, context) else { throw VersionError.versionMissing }
            guard !deck.isLocked else { throw VersionError.locked }
            _ = try commit(deck: deck, branch: current, name: "", kind: .auto, note: "Before branching to \(name)", onlyIfChanged: true, context)
            branch = DeckBranch(deckID: deckID, name: name, tipVersionID: version.id)
            replaceList(of: deck, with: version.rows, context)
        } else {
            // A branch needs somewhere to start: with nothing saved yet,
            // the list as it stands is saved first, on the branch it is on.
            if current.tipVersionID == nil {
                _ = try commit(deck: deck, branch: current, name: "", kind: .auto, note: "Before branching to \(name)", onlyIfChanged: false, context)
                branch = DeckBranch(deckID: deckID, name: name, tipVersionID: current.tipVersionID)
            } else {
                branch = DeckBranch(deckID: deckID, name: name, tipVersionID: current.tipVersionID)
            }
        }
        context.insert(branch)
        deck.currentBranchID = branch.id
        try finish(deck, context)
        return branch
    }

    /// Makes `branchID` the branch the list is on: unsaved changes are
    /// saved on the one being left, and the list becomes the new one's tip.
    static func switchBranch(deckID: UUID, to branchID: UUID, context: ModelContext) throws {
        let deck = try fetchDeck(deckID, context)
        guard let target = try fetchBranch(branchID, context), target.deckID == deckID else { throw VersionError.branchMissing }
        guard deck.currentBranchID != branchID else { return }
        guard !deck.isLocked else { throw VersionError.locked }
        let current = try currentBranch(of: deck, context)
        _ = try commit(deck: deck, branch: current, name: "", kind: .auto, note: "Before switching to \(target.name)", onlyIfChanged: true, context)
        if let tip = try target.tipVersionID.flatMap({ try fetchVersion($0, context) }) {
            replaceList(of: deck, with: tip.rows, context)
        }
        deck.currentBranchID = target.id
        try finish(deck, context)
    }

    static func renameBranch(_ branchID: UUID, to raw: String, context: ModelContext) throws {
        guard let branch = try fetchBranch(branchID, context) else { throw VersionError.branchMissing }
        branch.name = try validated(raw, deckID: branch.deckID, except: branchID, context)
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    /// Deletes a branch that isn't the current one, and the versions only
    /// it reached.
    static func deleteBranch(_ branchID: UUID, context: ModelContext) throws {
        guard let branch = try fetchBranch(branchID, context) else { return }
        let deckID = branch.deckID
        let deck = try fetchDeck(deckID, context)
        guard deck.currentBranchID != branchID else { throw VersionError.lastBranch }
        context.delete(branch)
        let remaining = try branches(of: deckID, context).filter { $0.id != branchID }
        let versions = try versions(of: deckID, context)
        let tree = DeckVersionTree(parents: versions.map { ($0.id, $0.parentID) })
        let orphaned = tree.unreachable(from: remaining.map(\.tipVersionID))
        for version in versions where orphaned.contains(version.id) { context.delete(version) }
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    static func renameVersion(_ versionID: UUID, to name: String, context: ModelContext) throws {
        guard let version = try fetchVersion(versionID, context) else { throw VersionError.versionMissing }
        version.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Named, it is the user's: it no longer counts as automatic.
        if !version.name.isEmpty { version.kindRaw = DeckVersion.Kind.saved.rawValue }
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    // MARK: A built deck

    /// What changing a built deck's list did to its cards.
    nonisolated struct Rebuild: Sendable, Equatable {
        /// Copies sent home when the deck was taken apart.
        let returned: Int
        /// Copies built into the new list, and what it still lacks.
        let built: Int
        let missing: Int
    }

    /// Runs `change` — one of the list-changing writes above. On a deck
    /// that is built, the deck is taken apart first and built again from
    /// the new list afterwards, from the collections it was built from
    /// (and with its sideboard, if that was built); nil when the deck
    /// wasn't built and only the list changed. A locked deck is refused
    /// before anything moves.
    @discardableResult
    static func changingList(deckID: UUID, container: ModelContainer, _ change: () throws -> Void) async throws -> Rebuild? {
        let context = container.mainContext
        let deck = try fetchDeck(deckID, context)
        guard !deck.isLocked else { throw VersionError.locked }
        let builder = DeckBuilder.shared(for: container)
        let state = try await builder.builtState(deckID: deckID)
        guard state.copies > 0 else {
            try change()
            return nil
        }
        let apart = try await builder.disassemble(deckID: deckID)
        defer {
            CollectionChangeTracker.shared.bump()
            DeckChangeTracker.shared.bump()
        }
        try change()
        // The same collections, where they still exist; else all of them.
        let existing = Set(try context.fetch(FetchDescriptor<MTGCollection>()).map(\.name))
        let sources = state.sources.filter(existing.contains)
        let plan = try await builder.plan(deckID: deckID, sourceCollections: sources.isEmpty ? nil : sources,
                                          includeSideboard: state.includesSideboard)
        let result = try await builder.build(plan)
        return Rebuild(returned: apart.returnedCopies, built: result.movedCopies, missing: plan.missingCopies)
    }

    /// The name a new branch would take, or why it can't.
    static func checkBranchName(_ raw: String, deckID: UUID, context: ModelContext) throws {
        _ = try validated(raw, deckID: deckID, except: nil, context)
    }

    // MARK: Pieces

    /// What a version is called: its name, else why it exists, else when.
    nonisolated static func label(name: String, note: String, kind: DeckVersion.Kind, createdAt: Date) -> String {
        if !name.isEmpty { return name }
        if !note.isEmpty { return note }
        return (kind == .auto ? "Automatic · " : "Saved ") + createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    nonisolated static func label(of version: DeckVersion) -> String {
        label(name: version.name, note: version.note, kind: version.kind, createdAt: version.createdAt)
    }

    /// The deck's current branch, made on first use: "Main", with nothing
    /// saved on it yet.
    static func currentBranch(of deck: Deck, _ context: ModelContext) throws -> DeckBranch {
        if let id = deck.currentBranchID, let branch = try fetchBranch(id, context) { return branch }
        if let existing = try branches(of: deck.id, context).first {
            deck.currentBranchID = existing.id
            return existing
        }
        let branch = DeckBranch(deckID: deck.id, name: DeckBranch.defaultName, tipVersionID: nil)
        context.insert(branch)
        deck.currentBranchID = branch.id
        return branch
    }

    /// The list becomes `rows`. Rows for a card already on its board keep
    /// their identity (and so their place on screen); the rest are made
    /// or removed.
    private static func replaceList(of deck: Deck, with rows: [DeckVersionRow], _ context: ModelContext) {
        var existing: [String: DeckCard] = [:]
        for card in deck.cards {
            let key = DeckVersionRow(card).key
            if existing[key] == nil { existing[key] = card } else { context.delete(card) }
        }
        var kept = Set<String>()
        for row in DeckVersionRow.normalized(rows) {
            kept.insert(row.key)
            if let card = existing[row.key] {
                card.quantity = row.quantity
                card.scryfallID = row.scryfallID
                card.name = row.name
            } else {
                let card = DeckCard(scryfallID: row.scryfallID, oracleID: row.oracleID, name: row.name, board: row.deckBoard, quantity: row.quantity)
                card.deck = deck
                context.insert(card)
            }
        }
        for (key, card) in existing where !kept.contains(key) { context.delete(card) }
    }

    /// Folds away the oldest automatic versions past the limit: one that
    /// is no branch's tip and that nothing forks from is removed and its
    /// child re-parented, so the chain stays whole.
    private static func prune(deckID: UUID, _ context: ModelContext) throws {
        let all = try versions(of: deckID, context)
        let autos = all.filter { $0.kind == .auto && $0.name.isEmpty }.sorted { $0.createdAt > $1.createdAt }
        guard autos.count > automaticLimit else { return }
        let tips = Set(try branches(of: deckID, context).compactMap(\.tipVersionID))
        var children: [UUID: [DeckVersion]] = [:]
        for version in all { if let p = version.parentID { children[p, default: []].append(version) } }
        for old in autos.dropFirst(automaticLimit) {
            let kids = children[old.id] ?? []
            guard !tips.contains(old.id), kids.count == 1, let child = kids.first else { continue }
            child.parentID = old.parentID
            if let p = old.parentID { children[p, default: []].append(child) }
            children[old.id] = nil
            context.delete(old)
        }
    }

    private static func validated(_ raw: String, deckID: UUID, except: UUID?, _ context: ModelContext) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw VersionError.emptyName }
        let taken = try branches(of: deckID, context).contains { $0.id != except && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard !taken else { throw VersionError.nameTaken }
        return name
    }

    private static func finish(_ deck: Deck, _ context: ModelContext) throws {
        deck.updatedDate = Date()
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    private static func fetchDeck(_ id: UUID, _ context: ModelContext) throws -> Deck {
        guard let deck = try context.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })).first else {
            throw VersionError.deckMissing
        }
        return deck
    }

    private static func fetchVersion(_ id: UUID, _ context: ModelContext) throws -> DeckVersion? {
        try context.fetch(FetchDescriptor<DeckVersion>(predicate: #Predicate { $0.id == id })).first
    }

    private static func fetchBranch(_ id: UUID, _ context: ModelContext) throws -> DeckBranch? {
        try context.fetch(FetchDescriptor<DeckBranch>(predicate: #Predicate { $0.id == id })).first
    }

    private static func versions(of deckID: UUID, _ context: ModelContext) throws -> [DeckVersion] {
        try context.fetch(FetchDescriptor<DeckVersion>(predicate: #Predicate { $0.deckID == deckID }))
    }

    private static func branches(of deckID: UUID, _ context: ModelContext) throws -> [DeckBranch] {
        try context.fetch(FetchDescriptor<DeckBranch>(predicate: #Predicate { $0.deckID == deckID }, sortBy: [SortDescriptor(\.createdAt)]))
    }
}
