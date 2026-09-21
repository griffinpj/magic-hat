//
//  CollectionSummary.swift
//  magic-hat
//
//  What the Collections tab shows per collection. A plain value produced by
//  CollectionStore off the main actor, so the home tab never has to load
//  every entry in the store just to draw a few cards.
//

import Foundation

nonisolated struct CollectionSummary: Identifiable, Hashable, Sendable {
    let name: String
    let uniqueCards: Int
    let totalCopies: Int
    let totalValue: Double
    /// Highest-value cards, for the thumbnail fan.
    let highlights: [Highlight]
    var id: String { name }

    struct Highlight: Identifiable, Hashable, Sendable {
        let id: String
        let imageURL: String?
        let aspectRatio: Double
    }
}
