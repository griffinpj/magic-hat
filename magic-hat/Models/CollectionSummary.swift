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
    /// A list's summary (see CollectionKind); decoded as false from an
    /// overview saved before lists existed.
    var isList = false
    let uniqueCards: Int
    let totalCopies: Int
    let totalValue: Double
    /// Highest-value cards, for the thumbnail fan.
    let highlights: [Highlight]
    // What the tab says beyond the count and the value. Optional, so an
    // overview saved before they existed (LastOverview) still decodes.
    /// Copies in a foil or etched finish.
    var foils: Int? = nil
    /// Distinct sets.
    var sets: Int? = nil
    /// What was paid for the rows that carry a price in the display
    /// currency, and what those same rows are worth now.
    var paidValue: Double? = nil
    var marketOfPaid: Double? = nil
    /// Copies by colour: "W" … "G", "M" for more than one colour, "C" for
    /// none — each card counted once.
    var colorCounts: [String: Int]? = nil
    /// On a list: copies of cards owned somewhere, in any printing.
    var ownedCopies: Int? = nil
    var id: String { name }

    /// Up or down against what was paid, over the rows that know it.
    var gainLoss: (amount: Double, percent: Double)? {
        guard let paid = paidValue, paid > 0, let market = marketOfPaid else { return nil }
        return (market - paid, (market - paid) / paid * 100)
    }

    /// The colour keys in the order a bar draws them.
    static let colorOrder = ["W", "U", "B", "R", "G", "M", "C"]

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

/// The last overview the Collections tab computed, kept in UserDefaults so
/// the tab's first frame shows its numbers rather than a loading card while
/// every row is read (0.6s on the real collection in a debug build — and
/// seconds when the launch is stalled behind a debugger's library loads).
/// Read once, synchronously: a few KB, from defaults already in memory. The
/// fresh overview replaces it the moment it lands. Per store, and never for
/// the in-memory stores of seeded UI tests.
nonisolated enum LastOverview {
    private static var key: String? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uitest-seed") { return nil }
        return arguments.contains("-uitest-real") ? "collections.lastOverview.uitest-real" : "collections.lastOverview"
    }

    static let saved: CollectionOverview? = {
        guard let key, let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CollectionOverview.self, from: data)
    }()

    static func save(_ overview: CollectionOverview) {
        guard let key, let data = try? JSONEncoder().encode(overview) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
