//
//  CollectionSummary.swift
//  magic-hat
//
//  What the Collections tab shows per collection. A plain value produced by
//  CollectionStore off the main actor, so the home tab never has to load
//  every entry in the store just to draw a few cards.
//

import Foundation

nonisolated struct CollectionSummary: Identifiable, Hashable, Sendable, Codable {
    let name: String
    let uniqueCards: Int
    let totalCopies: Int
    let totalValue: Double
    /// Highest-value cards, for the thumbnail fan.
    let highlights: [Highlight]
    var id: String { name }

    struct Highlight: Identifiable, Hashable, Sendable, Codable {
        let id: String
        let imageURL: String?
        let aspectRatio: Double
    }
}

/// The synthetic "All Collection": every owned row across every
/// collection and every built deck, so the user can see everything they
/// hold in one grid. It is a scope the store understands, not an
/// MTGCollection row — nothing can be imported into it or deleted from it.
nonisolated enum CollectionScope {
    static let allKey = "*all*"
    static let allName = "All Collection"

    static func isAll(_ name: String) -> Bool { name == allKey }
    static func displayName(_ name: String) -> String { isAll(name) ? allName : name }
}

/// The Collections tab in one value: each collection, the whole library,
/// and how much of it sits in built decks. Codable so the last one can be
/// shown the moment the tab appears after a launch (see CollectionsView).
nonisolated struct CollectionOverview: Hashable, Sendable, Codable {
    let collections: [CollectionSummary]
    let all: CollectionSummary
    let deckCopies: Int
    let deckValue: Double
    /// Collection names found on owned rows, decks' hidden ones left out —
    /// what the tab backfills MTGCollection rows from.
    var entryCollectionNames: Set<String> = []

    var collectionCopies: Int { all.totalCopies - deckCopies }
    var collectionValue: Double { all.totalValue - deckValue }
    var deckFraction: Double { all.totalCopies > 0 ? Double(deckCopies) / Double(all.totalCopies) : 0 }
}
