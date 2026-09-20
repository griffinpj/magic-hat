//
//  ManaBoxRow.swift
//  magic-hat
//
//  Plain value type for a single parsed row of a ManaBox collection CSV.
//  This is the on-disk import schema; it maps 1:1 to the export columns.
//

import Foundation

nonisolated struct ManaBoxRow: Identifiable, Hashable, Sendable {
    let id = UUID()

    var binderName: String
    var binderType: String
    var name: String
    var setCode: String
    var setName: String
    var collectorNumber: String
    var foil: String            // "normal" | "foil" | "etched"
    var rarity: String
    var quantity: Int
    var manaBoxID: String
    var scryfallID: String
    var purchasePrice: Double?
    var misprint: Bool
    var altered: Bool
    var condition: String
    var language: String
    var purchasePriceCurrency: String
    var added: Date?

    var finish: CardFinish {
        CardFinish(rawValue: foil.lowercased()) ?? .normal
    }

    /// Expected header order in a ManaBox export.
    static let expectedHeader = [
        "Binder Name", "Binder Type", "Name", "Set code", "Set name",
        "Collector number", "Foil", "Rarity", "Quantity", "ManaBox ID",
        "Scryfall ID", "Purchase price", "Misprint", "Altered", "Condition",
        "Language", "Purchase price currency", "Added"
    ]
}
