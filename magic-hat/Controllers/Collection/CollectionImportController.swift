//
//  CollectionImportController.swift
//  magic-hat
//
//  Puts an imported list's rows (CardListFile) into a collection or list
//  as one History action. Each row is matched to a printing by the best
//  thing it carries: its Scryfall id; its set and collector number; its
//  name in the set it names (a set given by name is looked up in
//  Scryfall's set list); its name alone — the catalog first, Scryfall for
//  what the catalog lacks. Finish, condition, language and the price paid
//  come from the row; a row that says nothing takes the app's defaults,
//  as an Add does. Rows that match nothing are named in the outcome,
//  never dropped silently.
//

import Foundation
import SwiftData

@MainActor
enum CollectionImportController {
    struct Outcome: Sendable {
        let copies: Int
        let rows: Int
        let unresolved: [String]
    }

    /// `remote: false` matches against the catalog only (tests, a seeded
    /// run): no set-name lookup, no Scryfall fallback.
    static func importCards(_ cards: [ImportedCard], into collection: String, container: ModelContainer,
                            remote: Bool = true) async throws -> Outcome {
        var cards = cards
        if remote { await fillSetCodes(&cards) }

        // 1. Rows that carry a Scryfall id: make sure the catalog has them.
        let ids = Array(Set(cards.compactMap(\.scryfallID)))
        let store = DeckStore.shared(for: container)
        var byID: [String: CardItem] = [:]
        /// Catalog cards for ids, 500 to a query.
        func load(_ ids: [String]) async throws {
            for chunk in ids.chunked(into: 500) {
                for item in try await store.items(scryfallIDs: chunk) { byID[item.scryfallID] = item }
            }
        }
        try await load(ids)
        let unknown = ids.filter { byID[$0] == nil }
        if remote, !unknown.isEmpty, let fetched = try? await ScryfallClient.shared.cards(ids: unknown), !fetched.isEmpty {
            for batch in fetched.chunked(into: 75) {
                try? await CardMetaWriter.shared(for: container).apply(cards: batch, linkEntries: false)
            }
            try await load(unknown)
        }

        // 2. The rest, by printing or name, as a deck list's lines are.
        let pending = cards.enumerated().filter { $0.element.scryfallID.flatMap { byID[$0] } == nil }
        let lines = pending.map { _, card in
            DeckListLine(quantity: card.quantity, name: card.name, setCode: card.setCode, collectorNumber: card.collectorNumber,
                         isFoil: card.finish != .normal, board: .main, raw: card.name)
        }
        let resolved = try await DeckImportController.resolve(lines, container: container, remote: remote)
        var resolvedID: [Int: String] = [:]
        for (slot, line) in zip(pending.map(\.offset), resolved) { resolvedID[slot] = line.scryfallID }
        try await load(Array(Set(resolvedID.values)).filter { byID[$0] == nil })

        // 3. One add per row.
        let displayCurrency = AppSettings.currency.code
        let defaultLanguage = AppSettings.cardLanguage
        var requests: [CollectionEditController.AddRequest] = []
        var unresolved: [String] = []
        for (index, card) in cards.enumerated() {
            let id = card.scryfallID.flatMap { byID[$0] == nil ? nil : $0 } ?? resolvedID[index]
            guard let id, let item = byID[id] else { unresolved.append(card.name); continue }
            let printing = PrintingSelection(item: item)
            // The price paid, when the file gives one in the currency
            // shown; else today's, as an Add starts with.
            let paid = card.purchasePrice.flatMap { price in
                card.purchaseCurrency.map { $0 == displayCurrency } ?? true ? price : nil
            }
            requests.append(.init(printing: printing, collectionName: collection, quantity: card.quantity, finish: card.finish,
                                  condition: card.condition, language: card.language ?? defaultLanguage,
                                  purchasePrice: paid ?? printing.marketPrice(for: card.finish)))
        }
        if !requests.isEmpty { try await CollectionEditController.addMany(requests, context: container.mainContext) }
        return Outcome(copies: requests.reduce(0) { $0 + $1.quantity }, rows: requests.count, unresolved: unresolved)
    }

    /// Set codes for rows that name their set in words ("Magic 2011"),
    /// from Scryfall's set list (cached a day).
    private static func fillSetCodes(_ cards: inout [ImportedCard]) async {
        guard cards.contains(where: { $0.setCode == nil && $0.setName != nil }),
              let sets = try? await ScryfallCatalogCache.shared.sets() else { return }
        let codes = setCodes(byName: sets.compactMap { set in set.name.map { (name: $0, code: set.code) } })
        for i in cards.indices where cards[i].setCode == nil {
            if let name = cards[i].setName, let code = codes[foldSetName(name)] { cards[i].setCode = code }
        }
    }

    nonisolated static func foldSetName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    nonisolated static func setCodes(byName sets: [(name: String, code: String)]) -> [String: String] {
        Dictionary(sets.map { (foldSetName($0.name), $0.code.lowercased()) }, uniquingKeysWith: { a, _ in a })
    }
}
