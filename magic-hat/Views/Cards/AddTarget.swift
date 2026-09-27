//
//  AddTarget.swift
//  magic-hat
//
//  Which collection an Add starts on, so the sheet opens ready to add
//  rather than asking "Choose a collection" every time. The screen being
//  browsed says where it is through the environment (a collection's grid
//  sets it; the Search tab and decks don't), and the sheet resolves in
//  order: that collection, the row's own collection when an owned row is
//  being re-added, the last collection added to, and the only collection
//  when there is just one. A name that no longer exists is skipped.
//

import SwiftUI

extension EnvironmentValues {
    /// The collection the user is browsing, when that is one collection
    /// (not All Collection, not a deck). Presented sheets inherit it.
    @Entry var browsingCollection: String? = nil
}

nonisolated enum AddTarget {
    /// Remembered across launches; written on each successful add.
    static let lastKey = "add.lastCollection"

    static func resolve(browsing: String?, item: CardItem, last: String?, existing: [String]) -> String {
        let names = Set(existing)
        let candidates: [String?] = [
            browsing,
            item.isEntry ? item.collectionName : nil,
            last,
            existing.count == 1 ? existing.first : nil,
        ]
        for case let name? in candidates where names.contains(name) && !Deck.isDeckCollection(name) {
            return name
        }
        return ""
    }
}
