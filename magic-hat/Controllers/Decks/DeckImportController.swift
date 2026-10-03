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
    /// `remote: false` stops at the catalog (tests, and a seeded run).
    static func resolve(_ lines: [DeckListLine], container: ModelContainer, remote: Bool = true) async throws -> [ResolvedDeckLine] {
        let store = DeckStore.shared(for: container)
        var resolved = try await store.resolve(lines)
        let missing = resolved.filter { !$0.isResolved }.map(\.line)
        guard !missing.isEmpty, remote else { return resolved }

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
        // A printing Scryfall didn't have under that set and number: the
        // card by its name instead.
        let foundPrintings = Set(found.map { "\($0.set.lowercased())|\($0.collectorNumber)" })
        let byNameRetry = missing.filter { line in
            guard let set = line.setCode, let number = line.collectorNumber else { return false }
            return !foundPrintings.contains("\(set.lowercased())|\(number)")
        }.map { ScryfallCardIdentifier(name: $0.name) }
        for chunk in Array(Set(byNameRetry)).chunked(into: ScryfallClient.collectionBatchSize) {
            if let response = try? await ScryfallClient.shared.collection(identifiers: chunk) {
                found.append(contentsOf: response.data)
            }
        }
        guard !found.isEmpty else { return resolved }
        try? await CardMetaWriter.shared(for: container).apply(cards: found, linkEntries: false)
        resolved = try await store.resolve(lines)
        // Scryfall matches names whatever their case or accents; the
        // catalog lookup is exact. What it still misses is matched here
        // against what came back.
        return patch(resolved, with: found)
    }

    /// Fills unresolved lines from fetched cards: the printing by set and
    /// number, else the name folded (case, accents, a front face).
    nonisolated static func patch(_ resolved: [ResolvedDeckLine], with found: [ScryfallCard]) -> [ResolvedDeckLine] {
        var byPrinting: [String: ScryfallCard] = [:]
        var byName: [String: ScryfallCard] = [:]
        for card in found {
            byPrinting["\(card.set.lowercased())|\(card.collectorNumber)"] = card
            let folded = CardTextReader.fold(card.name)
            if byName[folded] == nil { byName[folded] = card }
        }
        return resolved.map { line in
            guard !line.isResolved else { return line }
            var card: ScryfallCard?
            if let set = line.line.setCode, let number = line.line.collectorNumber { card = byPrinting["\(set.lowercased())|\(number)"] }
            if card == nil { card = byName[CardTextReader.fold(line.line.name)] }
            guard let card else { return line }
            return ResolvedDeckLine(line: line.line, scryfallID: card.id, oracleID: card.bestOracleID, canonicalName: card.name)
        }
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
