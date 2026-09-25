//
//  CardViewerSession.swift
//  magic-hat
//
//  Everything a presented CardViewerView needs, carried *in the presented
//  item*. Presenting with `.fullScreenCover(item:)` and reading the items
//  and current id from the presenter's other @State properties showed a
//  blank viewer from a deck's search results: inside an active search
//  session the presentation closure was evaluated against a copy of the
//  presenter whose state was still at its initial values, so the viewer
//  got no items and no current card. The item is the one thing SwiftUI
//  hands the closure fresh, so the items ride along in it, and the current
//  id is observable state on the same object so paging still round-trips.
//

import Foundation
import Observation

@MainActor @Observable
final class CardViewerSession: Identifiable {
    let id = UUID()
    let items: CardItemList
    var currentID: String?
    /// Set when opened from a deck's add sheet: the viewer's −/+ count and
    /// change the card's copies on that deck's board.
    let deck: DeckAddSession?

    init(items: [CardItem], currentID: String?, deck: DeckAddSession? = nil) {
        self.items = CardItemList(items)
        self.currentID = currentID
        self.deck = deck
    }
}
