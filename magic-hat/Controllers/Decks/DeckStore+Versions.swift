//
//  DeckStore+Versions.swift
//  magic-hat
//
//  Reads for a deck's Versions screen, off the main thread like the rest
//  of DeckStore: the branches, the current branch's versions newest first
//  with where other branches sit on them, what is unsaved, and any two
//  lists compared card by card with their totals.
//

import Foundation
import SwiftData

/// A list to compare: the deck as it stands, a saved version, the version
/// before one, or a branch's newest.
nonisolated enum DeckListRef: Hashable, Sendable {
    case working
    case version(UUID)
    case parent(of: UUID)
    case branch(UUID)
}

nonisolated struct DeckVersionInfo: Identifiable, Hashable, Sendable {
    /// Another branch, as it relates to a version on the current one.
    enum Mark: Hashable, Sendable {
        /// That branch's newest version is this one.
        case tip(String)
        /// That branch splits off after this one.
        case fork(String)
    }

    let id: UUID
    let title: String
    let createdAt: Date
    let isAutomatic: Bool
    let added: Int
    let removed: Int
    let cardCount: Int
    var marks: [Mark] = []

    /// "+3 −2 · 100 cards"
    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if removed > 0 { parts.append("−\(removed)") }
        let change = parts.joined(separator: " ")
        let cards = cardCount == 1 ? "1 card" : "\(cardCount) cards"
        return change.isEmpty ? cards : "\(change) · \(cards)"
    }
}

nonisolated struct DeckBranchInfo: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let isCurrent: Bool
    let tipID: UUID?
    /// When its newest version was saved.
    let updatedAt: Date?
    let versionCount: Int
    /// Versions it has that the current branch doesn't, and the reverse.
    let ahead: Int
    let behind: Int
    let cardCount: Int

    /// "5 versions", or against the current branch "2 of its own · 1 behind".
    var caption: String {
        if isCurrent || (ahead == 0 && behind == 0) {
            return versionCount == 1 ? "1 version" : "\(versionCount) versions"
        }
        var parts: [String] = []
        if ahead > 0 { parts.append(ahead == 1 ? "1 version of its own" : "\(ahead) versions of its own") }
        if behind > 0 { parts.append("\(behind) behind") }
        return parts.joined(separator: " · ")
    }
}

nonisolated struct DeckVersionsSnapshot: Hashable, Sendable {
    let deckName: String
    let isLocked: Bool
    let branches: [DeckBranchInfo]
    /// The current branch's versions, newest first.
    let versions: [DeckVersionInfo]
    /// The list against the current branch's newest version.
    let unsaved: DeckListDiff
    /// Nothing has been saved on the deck yet.
    let isUntracked: Bool
    let workingCardCount: Int
    /// Physical copies in the deck: changing its list rebuilds it.
    var builtCopies = 0
    var isBuilt: Bool { builtCopies > 0 }

    var current: DeckBranchInfo? { branches.first(where: \.isCurrent) }
    var others: [DeckBranchInfo] { branches.filter { !$0.isCurrent } }
}

nonisolated struct DeckComparison: Hashable, Sendable {
    struct Item: Identifiable, Hashable, Sendable {
        let change: DeckListChange
        let card: CardItem
        var id: String { change.id }
    }

    struct Group: Identifiable, Hashable, Sendable {
        enum Kind: String, Sendable { case added, removed, changed, moved }
        let kind: Kind
        let items: [Item]
        var id: String { kind.rawValue }
        var copies: Int {
            switch kind {
            case .added, .changed: return items.reduce(0) { $0 + max(0, $1.change.delta) }
            case .removed: return items.reduce(0) { $0 + max(0, -$1.change.delta) }
            case .moved: return items.reduce(0) { $0 + $1.change.to }
            }
        }
    }

    struct Totals: Hashable, Sendable {
        var cards = 0
        var value = 0.0
        var lands = 0
        /// Mean mana value of the nonland cards.
        var averageManaValue = 0.0
    }

    /// The title of a side with nothing on it (before the first version).
    static let nothing = "Nothing"

    let fromTitle: String
    let toTitle: String
    let groups: [Group]
    let before: Totals
    let after: Totals
    let diff: DeckListDiff

    var isEmpty: Bool { groups.isEmpty }
}

extension DeckStore {
    private func versionModels(_ deckID: UUID) throws -> [DeckVersion] {
        try modelContext.fetch(FetchDescriptor<DeckVersion>(predicate: #Predicate { $0.deckID == deckID }))
    }

    private func branchModels(_ deckID: UUID) throws -> [DeckBranch] {
        try modelContext.fetch(FetchDescriptor<DeckBranch>(predicate: #Predicate { $0.deckID == deckID }, sortBy: [SortDescriptor(\.createdAt)]))
    }

    private func deckModel(_ id: UUID) throws -> Deck? {
        try modelContext.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })).first
    }

    private static func title(_ version: DeckVersion) -> String {
        DeckVersionController.label(name: version.name, note: version.note, kind: version.kind, createdAt: version.createdAt)
    }

    /// The Versions screen in one value; nil when the deck is gone.
    func versions(deckID: UUID) throws -> DeckVersionsSnapshot? {
        guard let deck = try deckModel(deckID) else { return nil }
        let versions = try versionModels(deckID)
        let branches = try branchModels(deckID)
        let byID = Dictionary(versions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tree = DeckVersionTree(parents: versions.map { ($0.id, $0.parentID) })
        let current = branches.first { $0.id == deck.currentBranchID } ?? branches.first
        let currentPath = tree.path(from: current?.tipVersionID)
        let onCurrent = Set(currentPath)

        var marks: [UUID: [DeckVersionInfo.Mark]] = [:]
        var infos: [DeckBranchInfo] = []
        for branch in branches {
            let path = tree.path(from: branch.tipVersionID)
            let isCurrent = branch.id == current?.id
            let ahead = path.prefix { !onCurrent.contains($0) }.count
            let base = path.first { onCurrent.contains($0) }
            let behind = base.flatMap { currentPath.firstIndex(of: $0) } ?? currentPath.count
            let tip = branch.tipVersionID.flatMap { byID[$0] }
            infos.append(DeckBranchInfo(id: branch.id, name: branch.name, isCurrent: isCurrent, tipID: branch.tipVersionID,
                                        updatedAt: tip?.createdAt, versionCount: path.count,
                                        ahead: isCurrent ? 0 : ahead, behind: isCurrent ? 0 : behind, cardCount: tip?.cardCount ?? 0))
            if !isCurrent, let base {
                marks[base, default: []].append(ahead == 0 ? .tip(branch.name) : .fork(branch.name))
            }
        }
        // Before versions are first used there is no branch row yet: the
        // one the first save will make is shown, so the screen never
        // starts with an empty Branches list.
        if infos.isEmpty {
            infos.append(DeckBranchInfo(id: deckID, name: DeckBranch.defaultName, isCurrent: true, tipID: nil, updatedAt: nil,
                                        versionCount: 0, ahead: 0, behind: 0, cardCount: 0))
        }
        // The current one first, then the others, the most recently saved first.
        infos.sort { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
        }

        let history = currentPath.compactMap { id -> DeckVersionInfo? in
            guard let v = byID[id] else { return nil }
            return DeckVersionInfo(id: v.id, title: Self.title(v), createdAt: v.createdAt, isAutomatic: v.kind == .auto && v.name.isEmpty,
                                   added: v.added, removed: v.removed, cardCount: v.cardCount, marks: marks[v.id] ?? [])
        }
        let working = deck.cards.map(DeckVersionRow.init)
        let tipRows = current?.tipVersionID.flatMap { byID[$0] }?.rows ?? []
        let deckKey = deck.collectionKey
        let builtCopies = try modelContext.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.collectionName == deckKey }))
            .reduce(0) { $0 + $1.quantity }
        return DeckVersionsSnapshot(deckName: deck.name, isLocked: deck.isLocked, branches: infos, versions: history,
                                    unsaved: DeckListDiff.between(tipRows, working), isUntracked: currentPath.isEmpty,
                                    workingCardCount: DeckVersionRow.playedCopies(working), builtCopies: builtCopies)
    }

    /// Two of the deck's lists, card by card, with their totals. `to` is
    /// the newer side: what was added is in it and not in `from`.
    func compare(deckID: UUID, from: DeckListRef, to: DeckListRef) throws -> DeckComparison? {
        guard let deck = try deckModel(deckID) else { return nil }
        let versions = Dictionary(try versionModels(deckID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let branches = Dictionary(try branchModels(deckID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func resolve(_ ref: DeckListRef) -> (rows: [DeckVersionRow], title: String) {
            switch ref {
            case .working:
                return (deck.cards.map(DeckVersionRow.init), "Current List")
            case .version(let id):
                guard let v = versions[id] else { return ([], "Missing Version") }
                return (v.rows, Self.title(v))
            case .parent(let id):
                guard let parent = versions[id]?.parentID.flatMap({ versions[$0] }) else { return ([], DeckComparison.nothing) }
                return (parent.rows, Self.title(parent))
            case .branch(let id):
                guard let branch = branches[id] else { return ([], DeckComparison.nothing) }
                return (branch.tipVersionID.flatMap { versions[$0] }?.rows ?? [], branch.name)
            }
        }
        let old = resolve(from), new = resolve(to)
        let diff = DeckListDiff.between(old.rows, new.rows)

        // The catalog's cards for everything on either side.
        let ids = Array(Set((old.rows + new.rows).map(\.scryfallID)))
        var metas: [String: CardMeta] = [:]
        for chunk in ids.chunked(into: 500) {
            for meta in try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { chunk.contains($0.scryfallID) })) {
                metas[meta.scryfallID] = meta
            }
        }
        func card(_ row: DeckVersionRow) -> CardItem {
            let stand = DeckCard(scryfallID: row.scryfallID, oracleID: row.oracleID, name: row.name, board: row.deckBoard, quantity: row.quantity)
            return CardItem(deckCard: stand, meta: metas[row.scryfallID], quantity: row.quantity, owned: false)
        }
        func totals(_ rows: [DeckVersionRow]) -> DeckComparison.Totals {
            var t = DeckComparison.Totals()
            var nonland = 0
            var manaValue = 0
            for row in rows where row.deckBoard.isPlayed {
                let meta = metas[row.scryfallID]
                t.cards += row.quantity
                t.value += (meta?.price(foil: false, in: AppSettings.currency) ?? 0) * Double(row.quantity)
                if (meta?.typeLine ?? "").contains("Land") {
                    t.lands += row.quantity
                } else {
                    nonland += row.quantity
                    manaValue += ManaSymbol.manaValue(of: meta?.manaCost ?? "") * row.quantity
                }
            }
            t.averageManaValue = nonland == 0 ? 0 : Double(manaValue) / Double(nonland)
            return t
        }

        var grouped: [DeckComparison.Group.Kind: [DeckComparison.Item]] = [:]
        for change in diff.changes {
            let kind: DeckComparison.Group.Kind
            switch change.kind {
            case .added: kind = .added
            case .removed: kind = .removed
            case .count: kind = .changed
            case .moved: kind = .moved
            }
            grouped[kind, default: []].append(DeckComparison.Item(change: change, card: card(change.row)))
        }
        let order: [DeckComparison.Group.Kind] = [.added, .removed, .changed, .moved]
        let groups = order.compactMap { kind in grouped[kind].map { DeckComparison.Group(kind: kind, items: $0) } }
        return DeckComparison(fromTitle: old.title, toTitle: new.title, groups: groups,
                              before: totals(old.rows), after: totals(new.rows), diff: diff)
    }
}
