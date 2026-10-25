//
//  GridImageSizeTests.swift
//  magic-hatTests
//
//  The grid decodes a tile's image at the size it draws it, worked out
//  from the grid's width, not a fixed guess: the 150pt guess decoded
//  450px for a card a 440pt phone draws at 516px, and every tile was
//  upscaled. And the whole-collection prefetch asks the store for each
//  owned image once.
//

import Testing
import SwiftData
import UIKit
@testable import magic_hat

@Suite("Grid image size")
struct GridImageSizeTests {
    @Test @MainActor func threeWideOnALargePhoneDecodesAtTheDrawnHeight() {
        // 440pt across, three columns, 10pt gutters: a 133pt tile, a 123pt
        // card in its cell, 172pt tall — rounded up to 176.
        let size = CardTile.targetWidth(gridWidth: 440, columns: 3, spacing: 10, showsCaption: true)
        #expect(size == 176)
        #expect(size > CardTile.imageTargetWidth, "the fixed guess was too small for this phone")
    }

    @Test @MainActor func aNarrowPhoneDecodesLess() {
        // (375 − 40) / 3 = 112pt tile, 102pt card, 142pt tall → 144.
        let size = CardTile.targetWidth(gridWidth: 375, columns: 3, spacing: 10, showsCaption: true)
        #expect(size == 144)
        // Five across with no cell: 68pt card, 94pt tall → 96.
        let dense = CardTile.targetWidth(gridWidth: 375, columns: 5, spacing: 6, showsCaption: false)
        #expect(dense == 96)
    }

    @Test @MainActor func aPointOfWidthDoesNotChangeTheCacheKey() {
        let a = CardTile.targetWidth(gridWidth: 440, columns: 3, spacing: 10, showsCaption: true)
        let b = CardTile.targetWidth(gridWidth: 441, columns: 3, spacing: 10, showsCaption: true)
        #expect(a == b)
    }

    @Test @MainActor func anUnmeasuredGridUsesTheGuess() {
        #expect(CardTile.targetWidth(gridWidth: 0, columns: 3, spacing: 10, showsCaption: true) == CardTile.imageTargetWidth)
    }

    @Test @MainActor func ownedImageURLsListsEachImageOnce() async throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        context.insert(MTGCollection(name: "Main"))
        for (i, image) in ["a", "a", "b", nil].enumerated() {
            let meta = CardMeta(scryfallID: "id-\(i)", name: "Card \(i)", setCode: "tst", setName: "Test",
                                collectorNumber: "\(i)", rarity: "common", fetchState: .fetched)
            meta.imageNormalURL = image.map { "https://cards.scryfall.io/normal/\($0).jpg" }
            context.insert(meta)
            let entry = CollectionEntry(scryfallID: "id-\(i)", collectionName: "Main", quantity: 1)
            entry.card = meta
            context.insert(entry)
        }
        try context.save()
        let store = CollectionStore(modelContainer: container)
        let urls = try await store.ownedImageURLs()
        #expect(urls.sorted() == ["https://cards.scryfall.io/normal/a.jpg", "https://cards.scryfall.io/normal/b.jpg"])
    }
}
