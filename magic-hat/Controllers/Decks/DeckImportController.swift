//
//  DeckImportController.swift
//  magic-hat
//
//  Turns list text into a deck: parse, resolve against the catalog
//  (DeckStore, off-main), look up whatever the catalog didn't have on
//  Scryfall by name or printing (and cache it), then write the deck on the
//  main context. Reports what could not be found so the sheet can say so.
//

import Foundation
import SwiftData

@MainActor
enum DeckImportController {
    struct Outcome: Sendable {
        let deckID: UUID
        let importedCopies: Int
        let unresolved: [DeckListLine]
    }

    /// Resolves every line, locally first and then remotely for the rest.
    static func resolve(_ lines: [DeckListLine], container: ModelContainer) async throws -> [ResolvedDeckLine] {
        let store = DeckStore.shared(for: container)
        var resolved = try await store.resolve(lines)
        let missing = resolved.filter { !$0.isResolved }.map(\.line)
        guard !missing.isEmpty else { return resolved }

        // Scryfall accepts 75 identifiers per call; name lookups are exact
        // (front-face names work), printings by set + number.
        var identifiers: [ScryfallCardIdentifier] = []
        for line in missing {
            if let set = line.setCode, let number = line.collectorNumber {
                identifiers.append(ScryfallCardIdentifier(set: set, collectorNumber: number))
            } else {
                identifiers.append(ScryfallCardIdentifier(name: line.name))
            }
        }
        var found: [ScryfallCard] = []
        for chunk in Array(Set(identifiers)).chunked(into: ScryfallClient.collectionBatchSize) {
            if let response = try? await ScryfallClient.shared.collection(identifiers: chunk) {
                found.append(contentsOf: response.data)
            }
        }
        // Names that came back by name only: retry those printings by name.
        if !found.isEmpty {
            try? await CardMetaWriter.shared(for: container).apply(cards: found, linkEntries: false)
            resolved = try await store.resolve(lines)
        }
        return resolved
    }

    /// Creates the deck and fills it. `name` wins over the list's own title.
    static func importDeck(text: String, name: String, format: DeckFormat, container: ModelContainer) async throws -> Outcome {
        let list = DeckListParser.parse(text)
        let resolved = try await resolve(list.lines, container: container)
        let context = container.mainContext
        let deck = try DeckEditController.createDeck(name: name, format: format, commander: nil, context: context)
        let added = try DeckEditController.importLines(resolved, into: deck.id, context: context)
        // Cover: the commander's art if we have it.
        if let commander = resolved.first(where: { $0.line.board == .commander && $0.isResolved }),
           let id = commander.scryfallID,
           let meta = try? context.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { $0.scryfallID == id })).first {
            deck.coverArtURL = meta.artCropURL
            try? context.save()
        }
        return Outcome(deckID: deck.id, importedCopies: added, unresolved: resolved.filter { !$0.isResolved }.map(\.line))
    }
}
