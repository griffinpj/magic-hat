//
//  CardItemList.swift
//  magic-hat
//
//  A list of cards as a *view input*. SwiftUI decides whether a view needs
//  updating by comparing its inputs, and it compares an array element by
//  element — including the array a `ForEach` materialises from its data.
//  With the real collection (3,900 cards, ~40 fields each) that ran
//  0.86–1.14s on the main thread per hydration batch, sort and push
//  (HangDetector: AGDispatchEquatable → Array.== → CardItem.==).
//
//  So a list is handed to SwiftUI two ways, both cheap to compare: the
//  list itself, by a stamp taken at construction (an unchanged list is one
//  integer compare; a changed one still re-renders), and `ids`, a plain
//  [String] that a `ForEach` iterates — 3,900 short strings compare in
//  well under a millisecond — with each row fetching its card by id. Hold
//  one in state and assign a new one when the cards change; never build
//  one inside a body.
//

import Foundation
import os

nonisolated struct CardItemList: Equatable, Sendable {
    private final class Box: @unchecked Sendable {
        let items: [CardItem]
        private let lock = OSAllocatedUnfairLock<(ids: [String]?, index: [String: Int]?)>(initialState: (nil, nil))

        init(_ items: [CardItem]) { self.items = items }

        var ids: [String] {
            lock.withLock { state in
                if state.ids == nil { state.ids = items.map(\.id) }
                return state.ids!
            }
        }

        func index(of id: String) -> Int? {
            lock.withLock { state in
                if state.index == nil {
                    var built: [String: Int] = [:]
                    built.reserveCapacity(items.count)
                    for (i, item) in items.enumerated() where built[item.id] == nil { built[item.id] = i }
                    state.index = built
                }
                return state.index?[id]
            }
        }
    }

    private static let counter = OSAllocatedUnfairLock(initialState: UInt64(0))

    private let box: Box
    /// Fresh for every list built; what `==` compares.
    let stamp: UInt64

    init(_ items: [CardItem] = []) {
        box = Box(items)
        stamp = Self.counter.withLock { $0 &+= 1; return $0 }
    }

    var items: [CardItem] { box.items }
    var count: Int { box.items.count }
    var isEmpty: Bool { box.items.isEmpty }
    var first: CardItem? { box.items.first }

    /// The ids in order — what a ForEach iterates.
    var ids: [String] { box.ids }

    /// Position of a card in the list, or nil.
    func index(of id: String) -> Int? { box.index(of: id) }

    /// The card with this id, or nil.
    func item(for id: String?) -> CardItem? {
        guard let id, let i = box.index(of: id) else { return nil }
        return box.items[i]
    }

    static func == (lhs: CardItemList, rhs: CardItemList) -> Bool { lhs.stamp == rhs.stamp }
}
