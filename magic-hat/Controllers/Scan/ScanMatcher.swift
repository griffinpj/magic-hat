//
//  ScanMatcher.swift
//  magic-hat
//
//  From a reading to a printing, and how sure to be of each half.
//
//  The card: the printing's own address (set code + collector number, read
//  off the info block) is asked first, and counts only if its name agrees
//  with the title that was read — a number misread by a digit lands on
//  another card of the set, and the title catches it. Otherwise the title
//  goes to Scryfall's fuzzy name search: sure only when the name that comes
//  back is very close to what was read; close-ish is "unsure", and the user
//  is asked, with autocomplete's alternatives. Nothing is added on a guess.
//
//  The printing: with the name settled, whatever else was read narrows it
//  — the set code alone (`named?set=`), the number alone (`cn:`), the sets
//  the scanner is locked to, promos left out — through one printings
//  search (`printingQuery`). `exactPrinting` says the printing was read
//  off the card rather than chosen for it.
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
    /// The printing was read off the card, not chosen for it.
    let exactPrinting: Bool

    static func == (a: ScanMatch, b: ScanMatch) -> Bool {
        a.card.id == b.card.id && a.confidence == b.confidence && a.alternatives == b.alternatives && a.exactPrinting == b.exactPrinting
    }
}

nonisolated enum ScanOutcome: Sendable, Equatable {
    case match(ScanMatch)
    /// The card, but in none of the sets scanning is locked to.
    case outsideLockedSets(String)
    case nothing
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
        return similarity >= floorSimilarity ? .unsure : nil
    }

    /// The printings search that narrows a named card by what else was
    /// read and by the options; nil when nothing narrows it (the fuzzy
    /// match's own printing stands).
    static func printingQuery(name: String, reading: ScanReading, options: ScanMatchOptions,
                              currentSet: String?, currentPromo: Bool) -> String? {
        var parts = ["!\"\(name.replacingOccurrences(of: "\"", with: ""))\""]
        var narrows = false
        if !options.lockedSets.isEmpty, !(currentSet.map(options.lockedSets.contains) ?? false) {
            parts.append(CardSearchQuery.anyOf(options.lockedSets.sorted().map { "s:\($0)" }))
            narrows = true
        }
        if let number = reading.collectorNumber, reading.setCode == nil {
            parts.append("cn:\(number)")
            narrows = true
        }
        if options.ignorePromos, currentPromo {
            parts.append("-is:promo")
            narrows = true
        }
        return narrows ? parts.joined(separator: " ") : nil
    }

    static func match(_ reading: ScanReading, options: ScanMatchOptions = ScanMatchOptions(),
                      client: ScryfallClient = .shared) async -> ScanOutcome {
        // 1. The printing's own address.
        if let set = reading.setCode, let number = reading.collectorNumber,
           options.lockedSets.isEmpty || options.lockedSets.contains(set),
           let card = try? await client.card(setCode: set, collectorNumber: number),
           let confidence = confidence(read: reading.name, found: card.name, exactPrinting: true) {
            return .match(ScanMatch(card: card, confidence: confidence,
                                    alternatives: confidence == .sure ? [] : await alternatives(for: reading.name, client: client),
                                    exactPrinting: true))
        }

        // 2. The name, in the set that was read when there is one.
        guard let name = reading.name, name.count >= 3 else { return .nothing }
        let setRead = reading.setCode.flatMap { options.lockedSets.isEmpty || options.lockedSets.contains($0) ? $0 : nil }
        var found = try? await client.named(fuzzy: name, set: setRead)
        if found == nil, setRead != nil { found = try? await client.named(fuzzy: name) }
        guard var card = found, let confidence = confidence(read: name, found: card.name, exactPrinting: false) else {
            // Nothing close: still offer what the name could be.
            let names = await alternatives(for: name, client: client)
            guard let first = names.first, let card = try? await client.named(fuzzy: first) else { return .nothing }
            return .match(ScanMatch(card: card, confidence: .unsure, alternatives: Array(names.dropFirst()), exactPrinting: false))
        }

        // 3. The printing, narrowed by the number, the locked sets, promos.
        var exact = setRead != nil && card.set.lowercased() == setRead
        if let q = printingQuery(name: card.name, reading: reading, options: options,
                                 currentSet: card.set.lowercased(), currentPromo: card.promo == true) {
            if let page = try? await client.search(query: q, unique: "prints", order: "released", direction: "desc"),
               let first = page.cards.first {
                card = first
                exact = exact || (reading.collectorNumber != nil && page.cards.count == 1)
            } else if !options.lockedSets.isEmpty {
                return .outsideLockedSets(card.name)
            }
        }
        if !options.lockedSets.isEmpty, !options.lockedSets.contains(card.set.lowercased()) {
            return .outsideLockedSets(card.name)
        }
        return .match(ScanMatch(card: card, confidence: confidence,
                                alternatives: confidence == .sure ? [] : await alternatives(for: name, client: client).filter { $0 != card.name },
                                exactPrinting: exact))
    }

    private static func alternatives(for name: String?, client: ScryfallClient) async -> [String] {
        guard let name, name.count >= 3 else { return [] }
        let prefix = String(name.prefix(max(3, name.count / 2)))
        return Array(((try? await client.autocomplete(prefix)) ?? []).prefix(5))
    }
}
