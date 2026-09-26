//
//  HistoryDetail.swift
//  magic-hat
//
//  What one ledger action changed, card by card, for the History detail
//  screen: the records of the action merged per printing and grouped by
//  where the copies moved — a collection, or for a deck build the move
//  itself ("Main → Atraxa", one row per card rather than a −n and a +n).
//  Built off-main by CollectionStore; the screen shows the largest changes
//  first and at most `visibleLimit` per group, since an import is
//  thousands of rows, and filters the rest by name.
//

import Foundation

nonisolated struct HistoryChange: Identifiable, Hashable, Sendable {
    let id: String
    let scryfallID: String
    let name: String
    let setCode: String
    let collectorNumber: String
    let rarity: String?
    let finish: CardFinish
    let condition: String
    /// Signed copies; a move's copies are positive.
    let delta: Int
    var artCropURL: String?
    var imageURL: String?

    /// "#123 · Foil · Near Mint": the printing under the name.
    var printingLine: String {
        var parts: [String] = []
        if !collectorNumber.isEmpty { parts.append("#\(collectorNumber)") }
        if finish != .normal { parts.append(finish.displayName) }
        if let condition = CardCondition(rawValue: condition), condition != .nearMint {
            parts.append(condition.displayName)
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated struct HistoryChangeGroup: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Copies added to or removed from one collection.
        case scope
        /// Copies moved from one collection to another (a build, a
        /// disassembly): `title` is the source, `destination` where they went.
        case move
    }

    let id: String
    let kind: Kind
    let title: String
    let destination: String?
    /// Copies in and out over the whole group, before any cap.
    let added: Int
    let removed: Int
    /// Distinct printings in the group, before any cap.
    let total: Int
    /// The largest changes first; at most `HistoryDetail.visibleLimit`
    /// after `capped()`.
    let changes: [HistoryChange]

    var hidden: Int { total - changes.count }
}

nonisolated struct HistoryDetail: Hashable, Sendable {
    let actionID: UUID
    let groups: [HistoryChangeGroup]

    /// Rows shown per group before the rest is a search away.
    static let visibleLimit = 40

    /// Distinct printings across every group.
    var changeCount: Int { groups.reduce(0) { $0 + $1.total } }

    /// Each group cut to `visibleLimit` rows; `total` still counts them all.
    func capped(to limit: Int = visibleLimit) -> HistoryDetail {
        HistoryDetail(actionID: actionID, groups: groups.map { group in
            HistoryChangeGroup(id: group.id, kind: group.kind, title: group.title, destination: group.destination,
                               added: group.added, removed: group.removed, total: group.total,
                               changes: Array(group.changes.prefix(limit)))
        })
    }

    /// The changes whose card name contains `text` (case and diacritics
    /// aside); empty groups drop out. Empty text is everything.
    func filtered(_ text: String) -> HistoryDetail {
        let needle = text.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return self }
        let groups = groups.compactMap { group -> HistoryChangeGroup? in
            let matches = group.changes.filter {
                $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
            }
            guard !matches.isEmpty else { return nil }
            return HistoryChangeGroup(id: group.id, kind: group.kind, title: group.title, destination: group.destination,
                                      added: matches.filter { $0.delta > 0 }.reduce(0) { $0 + $1.delta },
                                      removed: -matches.filter { $0.delta < 0 }.reduce(0) { $0 + $1.delta },
                                      total: matches.count, changes: matches)
        }
        return HistoryDetail(actionID: actionID, groups: groups)
    }
}
