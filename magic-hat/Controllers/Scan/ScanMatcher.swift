//
//  ScanMatcher.swift
//  magic-hat
//
//  From a reading to a card, and how sure to be. The printing's own
//  address (set code + collector number, read off the info block) is
//  asked first: an exact printing whose name also matches the title is as
//  sure as a scan gets. Otherwise the title alone goes to Scryfall's fuzzy
//  name search — sure only when the name it returns is very close to what
//  was read; close-ish is "unsure", and the user is asked, with the names
//  Scryfall's autocomplete offers for the reading as alternatives. Nothing
//  is ever added on a guess.
//

import Foundation

nonisolated struct ScanMatch: Sendable, Equatable {
    enum Confidence: Sendable, Equatable {
        /// The printing and the name agree: add it.
        case sure
        /// A card, but not certainly this one: ask.
        case unsure
    }

    let card: ScryfallCard
    let confidence: Confidence
    /// Other names the reading might be, for the "Is this…?" prompt.
    let alternatives: [String]
    /// The printing was read off the card, not guessed.
    let exactPrinting: Bool

    static func == (a: ScanMatch, b: ScanMatch) -> Bool {
        a.card.id == b.card.id && a.confidence == b.confidence && a.alternatives == b.alternatives && a.exactPrinting == b.exactPrinting
    }
}

nonisolated enum ScanMatcher {
    /// A returned name this close to the reading counts as the same name.
    static let sureSimilarity = 0.88
    /// Below this the fuzzy answer is not worth showing.
    static let floorSimilarity = 0.55

    /// The verdict for a pair (read name, found name), for tests.
    static func confidence(read: String?, found: String, exactPrinting: Bool) -> ScanMatch.Confidence? {
        guard let read, !read.isEmpty else { return exactPrinting ? .unsure : nil }
        let similarity = CardTextReader.similarity(read, found)
        if similarity >= sureSimilarity { return .sure }
        if exactPrinting { return similarity >= floorSimilarity ? .unsure : nil }
        return similarity >= floorSimilarity ? .unsure : nil
    }

    static func match(_ reading: ScanReading, client: ScryfallClient = .shared) async -> ScanMatch? {
        if let set = reading.setCode, let number = reading.collectorNumber,
           let card = try? await client.card(setCode: set, collectorNumber: number),
           let confidence = confidence(read: reading.name, found: card.name, exactPrinting: true) {
            // A number misread by one digit lands on another card of the
            // set; the title catches it.
            return ScanMatch(card: card, confidence: confidence,
                             alternatives: confidence == .sure ? [] : await alternatives(for: reading.name, client: client),
                             exactPrinting: true)
        }
        guard let name = reading.name, name.count >= 3 else { return nil }
        guard let card = try? await client.named(fuzzy: name),
              let confidence = confidence(read: name, found: card.name, exactPrinting: false) else {
            // Nothing close: still offer what the name could be.
            let names = await alternatives(for: name, client: client)
            guard let first = names.first, let card = try? await client.named(fuzzy: first) else { return nil }
            return ScanMatch(card: card, confidence: .unsure, alternatives: Array(names.dropFirst()), exactPrinting: false)
        }
        return ScanMatch(card: card, confidence: confidence,
                         alternatives: confidence == .sure ? [] : await alternatives(for: name, client: client).filter { $0 != card.name },
                         exactPrinting: false)
    }

    private static func alternatives(for name: String?, client: ScryfallClient) async -> [String] {
        guard let name, name.count >= 3 else { return [] }
        let prefix = String(name.prefix(max(3, name.count / 2)))
        return Array(((try? await client.autocomplete(prefix)) ?? []).prefix(5))
    }
}
