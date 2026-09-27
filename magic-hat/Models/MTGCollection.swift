//
//  MTGCollection.swift
//  magic-hat
//
//  A named top-level collection of cards (the collection is the binder).
//  Import targets a single collection: an existing one to merge into, or a
//  new one. Named MTGCollection to avoid clashing with Swift's `Collection`.
//
//  A *list* is the same thing with one difference: its cards are not
//  owned. A wishlist, a trade want list, cards to proxy — rows with a
//  printing, finish, condition and quantity, browsed in the same grid,
//  edited with the same sheets and recorded in History, but left out of
//  everything that counts what you have: the overview's totals, All
//  Collection, "in collection" and "owned" marks, and the collections a
//  deck is built from. The ManaBox shape, where lists sit beside binders.
//

import Foundation
import SwiftData

nonisolated enum CollectionKind: String, Codable, CaseIterable, Sendable {
    case collection, list

    var noun: String { self == .collection ? "Collection" : "List" }
    var systemImage: String { self == .collection ? "tray.full" : "list.bullet.rectangle" }
}

@Model
nonisolated final class MTGCollection {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    var createdDate: Date
    /// `CollectionKind`; rows made before lists existed are collections.
    var kindRaw: String = CollectionKind.collection.rawValue

    var kind: CollectionKind {
        get { CollectionKind(rawValue: kindRaw) ?? .collection }
        set { kindRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), name: String, createdDate: Date = Date(), kind: CollectionKind = .collection) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
        self.kindRaw = kind.rawValue
    }
}
