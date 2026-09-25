//
//  EDHRECSynergyLoader.swift
//  magic-hat
//
//  EDHREC's page for a card, turned into cards of ours: for a commander,
//  every card played with it beyond chance (its synergy score), best
//  first; for any other card, the cards that turn up alongside it (lift).
//  Shared by the Synergies screen (a card at a time) and the deck's
//  Recommended list (the commander's whole list). Pages are cached a week;
//  ids the catalog lacks are looked up on Scryfall once and kept.
//

import Foundation

/// One card EDHREC puts next to another, as a row: the card, why, and
/// how many copies the collection holds.
nonisolated struct SynergyPick: Identifiable, Hashable, Sendable {
    let card: CardItem
    let reason: CardReason
    let score: Double
    let ownedCopies: Int
    var id: String { card.oracleID ?? card.scryfallID }
}

nonisolated enum EDHRECSynergyLoader {
    struct Result: Sendable {
        var picks: [SynergyPick] = []
        var unresolved: [String] = []
        var info: EDHRECCardInfo?
        var isCommanderPage = false
        /// False when EDHREC could not be reached and nothing was cached.
        var available = true
    }

    static let cache = DiskJSONCache(folder: "Synergies")
    static let ttl: TimeInterval = 7 * 24 * 3600

    /// The page's cards, best first, at most `limit` (nil for all).
    static func picks(for item: CardItem, limit: Int?, store: DeckStore, writer: CardMetaWriter) async -> Result {
        let slug = EDHRECClient.slug(for: item.name)
        guard !slug.isEmpty else { return Result() }
        let canCommand = (item.typeLine ?? "").contains("Legendary") && (item.typeLine ?? "").contains("Creature")
        var page: EDHRECPage?
        var commander = false
        if canCommand {
            let key = "edhrec-commander-\(slug)"
            if let cached = await cache.value(EDHRECPage.self, key: key, ttl: ttl) { page = cached; commander = true }
            else if let fetched = try? await EDHRECClient.shared.commanderPage(slug: slug) {
                await cache.store(fetched, key: key); page = fetched; commander = true
            }
        }
        if page == nil {
            let key = "edhrec-card-\(slug)"
            if let cached = await cache.value(EDHRECPage.self, key: key, ttl: ttl) { page = cached }
            else if let fetched = try? await EDHRECClient.shared.cardPage(slug: slug) {
                await cache.store(fetched, key: key); page = fetched
            }
        }
        guard let page else { return Result(available: false) }
        // Every list on the page, best first: synergy on a commander page,
        // lift above 1 on a card page. One row per card.
        var seen = Set<String>()
        var picked: [(id: String, view: EDHRECCardView, score: Double)] = []
        for list in page.cardlists {
            if ["newcards", "newcommanders", "topcommanders"].contains(list.tag ?? "") { continue }
            for view in list.cardviews {
                guard let id = view.id, !seen.contains(id) else { continue }
                let score: Double
                if commander { guard let s = view.synergy, s > 0 else { continue }; score = s }
                else { guard let l = view.lift, l > 1.0 else { continue }; score = l - 1 }
                seen.insert(id)
                picked.append((id, view, score))
            }
        }
        picked.sort { $0.score > $1.score }
        let top = limit.map { Array(picked.prefix($0)) } ?? picked
        var items = (try? await store.items(scryfallIDs: top.map(\.id))) ?? []
        let have = Set(items.map(\.scryfallID))
        let missing = top.map(\.id).filter { !have.contains($0) }
        if !missing.isEmpty {
            await fetchMissing(ids: missing, writer: writer)
            items = (try? await store.items(scryfallIDs: top.map(\.id))) ?? items
        }
        let owned = (try? await store.ownedCopiesByKey()) ?? [:]
        let byID = Dictionary(items.map { ($0.scryfallID, $0) }, uniquingKeysWith: { a, _ in a })
        var out = Result(info: page.card, isCommanderPage: commander)
        for entry in top {
            if let card = byID[entry.id] {
                out.picks.append(SynergyPick(card: card, reason: .synergy(entry.score, commander: commander), score: entry.score,
                                             ownedCopies: owned[card.oracleID ?? card.scryfallID] ?? 0))
            } else {
                out.unresolved.append(entry.view.name)
            }
        }
        return out
    }

    /// Cards the catalog lacks (a set newer than the last bulk ingest) are
    /// looked up on Scryfall once, by name or id, and kept. At most 75 a
    /// call (Scryfall's batch); a longer list takes the first 75 by name
    /// then by id.
    static func fetchMissing(names: [String] = [], ids: [String] = [], writer: CardMetaWriter) async {
        var identifiers = names.prefix(75).map { ScryfallCardIdentifier(name: $0) }
        identifiers.append(contentsOf: ids.prefix(max(0, 75 - identifiers.count)).map { ScryfallCardIdentifier(id: $0) })
        guard !identifiers.isEmpty,
              let fetched = try? await ScryfallClient.shared.collection(identifiers: identifiers), !fetched.data.isEmpty else { return }
        try? await writer.apply(cards: fetched.data, linkEntries: false)
    }
}
