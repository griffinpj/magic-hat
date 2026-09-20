//
//  CollectionEntry.swift
//  magic-hat
//
//  One row of owned copies: a specific card in a specific binder with a
//  specific finish/condition. Mirrors a ManaBox CSV row. Fields from the
//  CSV are denormalized here so the collection is browsable before any
//  Scryfall hydration happens.
//

import Foundation
import SwiftData

enum CardFinish: String, Codable, CaseIterable {
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
final class CollectionEntry {
    @Attribute(.unique) var id: UUID

    /// Links to `CardMeta.scryfallID` for hydrated metadata/images.
    var scryfallID: String

    var binderName: String
    var binderType: String

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

    /// Stable key for merge/upsert: same card + binder + finish + condition.
    var mergeKey: String {
        "\(scryfallID)|\(binderName)|\(finishRaw)|\(condition)"
    }

    init(
        id: UUID = UUID(),
        scryfallID: String,
        binderName: String,
        binderType: String = "binder",
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
        self.binderName = binderName
        self.binderType = binderType
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
