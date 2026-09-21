//
//  UITestSeed.swift
//  magic-hat
//
//  Deterministic fixture data for UI and performance tests, used when the app
//  is launched with `-uitest-seed`. In-memory store, no network: image URLs
//  are nil so tiles render their placeholder, and the catalog is marked ready
//  so the setup screen is skipped.
//

import Foundation
import SwiftData

@MainActor
enum UITestSeed {
    static let collectionName = "Test Collection"
    static let cardCount = 900

    static func populate(_ container: ModelContainer) {
        let context = container.mainContext
        context.insert(MTGCollection(name: collectionName))

        for i in 0..<cardCount {
            let id = String(format: "00000000-0000-4000-8000-%012d", i)
            let meta = CardMeta(
                scryfallID: id,
                name: "Card \(i)",
                setCode: ["one", "mom", "ltr", "woe"][i % 4],
                setName: "Set \(i % 4)",
                collectorNumber: "\(i)",
                rarity: ["common", "uncommon", "rare", "mythic"][i % 4],
                fetchState: .fetched
            )
            meta.priceUSD = Double(i % 50)
            meta.pricesUpdatedAt = Date()
            context.insert(meta)

            let entry = CollectionEntry(
                scryfallID: id,
                collectionName: collectionName,
                name: meta.name,
                setCode: meta.setCode,
                setName: meta.setName,
                collectorNumber: meta.collectorNumber,
                rarity: meta.rarity,
                finish: i % 7 == 0 ? .foil : .normal,
                quantity: 1 + i % 4,
                purchasePrice: Double(i % 40)
            )
            entry.card = meta
            context.insert(entry)
        }
        try? context.save()
        CatalogSyncController.shared.markCatalogReadyForTesting()
    }
}
