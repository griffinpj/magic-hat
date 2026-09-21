//
//  CollectionEntry.swift
//  magic-hat
//
//  One row of owned copies: a specific card, in a specific collection, with a
//  specific finish/condition. Mirrors a ManaBox CSV row minus its binder —
//  the collection IS the binder here, so the source binder is used only to
//  choose which rows to import and is not kept. Fields from the CSV are
//  denormalized so the collection is browsable before any Scryfall hydration.
//

import Foundation
import SwiftData

nonisolated enum CardFinish: String, Codable, CaseIterable, Sendable {
    case normal
    case foil
    case etched

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .foil: return "Foil"
        case .etched: return "Etched"
        }
    }
}

@Model
nonisolated final class CollectionEntry {
    @Attribute(.unique) var id: UUID

    // collectionName: every snapshot/summary predicate. scryfallID: the
    // IN-list lookups hydration uses to link entries to their CardMeta.
    #Index<CollectionEntry>([\.collectionName], [\.scryfallID])

    /// Links to `CardMeta.scryfallID` for hydrated metadata/images.
    var scryfallID: String

    /// The cached Scryfall record for this card. A real relationship (rather
    /// than a second unbounded @Query plus a dictionary join) lets the grid
    /// fetch entries and their metadata in one prefetching query.
    var card: CardMeta?

    /// Name of the owning collection (top level). Defaults so existing data
    /// migrates into a single collection.
    var collectionName: String = "My Collection"

    // Denormalized identity from the CSV (usable before hydration).
    var name: String
    var setCode: String
    var setName: String
    var collectorNumber: String
    var rarity: String

    var finishRaw: String
    var quantity: Int
    var condition: String
    var language: String

    var purchasePrice: Double?
    var purchasePriceCurrency: String?
    var manaBoxID: String?
    var addedDate: Date?

    var finish: CardFinish {
        get { CardFinish(rawValue: finishRaw) ?? .normal }
        set { finishRaw = newValue.rawValue }
    }

    /// Stable key for merge/upsert: same card + collection + finish +
    /// condition. Deliberately no binder — two copies of the same printing
    /// are the same row no matter which binder in the file they came from.
    var mergeKey: String {
        Self.mergeKey(scryfallID: scryfallID, collectionName: collectionName,
                      finish: finishRaw, condition: condition)
    }

    static func mergeKey(scryfallID: String, collectionName: String,
                         finish: String, condition: String) -> String {
        "\(scryfallID)|\(collectionName)|\(finish)|\(condition)"
    }

    init(
        id: UUID = UUID(),
        scryfallID: String,
        collectionName: String,
        name: String = "",
        setCode: String = "",
        setName: String = "",
        collectorNumber: String = "",
        rarity: String = "",
        finish: CardFinish = .normal,
        quantity: Int = 1,
        condition: String = "near_mint",
        language: String = "en",
        purchasePrice: Double? = nil,
        purchasePriceCurrency: String? = nil,
        manaBoxID: String? = nil,
        addedDate: Date? = nil
    ) {
        self.id = id
        self.scryfallID = scryfallID
        self.collectionName = collectionName
        self.name = name
        self.setCode = setCode
        self.setName = setName
        self.collectorNumber = collectorNumber
        self.rarity = rarity
        self.finishRaw = finish.rawValue
        self.quantity = quantity
        self.condition = condition
        self.language = language
        self.purchasePrice = purchasePrice
        self.purchasePriceCurrency = purchasePriceCurrency
        self.manaBoxID = manaBoxID
        self.addedDate = addedDate
    }
}
