//
//  CardSynergyController.swift
//  magic-hat
//
//  The cards that work with one card, from three places, each its own
//  section so the reader knows what kind of claim it is:
//
//  - Combos (Commander Spellbook): the other pieces of every combo the
//    card is in, with what the combo makes. Precise, and rare.
//  - Played with it (EDHREC): for a commander, its high-synergy cards —
//    played with it far more than with other commanders; for any other
//    card, the cards that turn up in decks with it beyond what chance
//    would give (lift), with the share of decks running each.
//  - Shares a theme (Scryfall): cards whose text touches the same
//    mechanics this card's does — read the way the deck analysis reads a
//    commander's engine — ordered by how widely they are played, and
//    within the deck's colour identity when opened from a deck.
//
//  Names come back from Spellbook and EDHREC; the catalog turns them into
//  CardItems (DeckStore, off the main actor) so every row gets the real
//  card UI — art, set symbol, price, owned marker — and a tap opens the
//  viewer. Answers are cached a week per card (DiskJSONCache).
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class CardSynergyController {
    enum State: Equatable {
        case loading, ready, empty, unavailable, offline
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let footer: String
        var state: State = .loading
        var items = CardItemList()
        /// One reason per card id, in the standard vocabulary.
        var reasons: [String: CardReason] = [:]
        /// Names the catalog could not turn into cards (still worth reading).
        var unresolved: [String] = []
    }

    private(set) var sections: [Section] = [
        Section(id: "combos", title: "Combos", footer: "Commander Spellbook"),
        Section(id: "edhrec", title: "Played With It", footer: "EDHREC"),
        Section(id: "theme", title: "Shares a Theme", footer: "Scryfall, by theme"),
    ]
    /// EDHREC's read of the card itself: share of decks, salt.
    private(set) var info: EDHRECCardInfo?
    private(set) var isCommanderPage = false

    private var loadTask: Task<Void, Never>?
    private var loadedFor: String?
    private static let cache = EDHRECSynergyLoader.cache
    static let ttl: TimeInterval = EDHRECSynergyLoader.ttl

    /// Loads everything for `item`. `identity` narrows the theme search
    /// to a deck's colours. Idempotent per card.
    func load(item: CardItem, identity: [ManaColor]?, container: ModelContainer) {
        let key = item.scryfallID + "|" + (identity?.map(\.rawValue).joined() ?? "*")
        guard key != loadedFor else { return }
        loadedFor = key
        loadTask?.cancel()
        for i in sections.indices { sections[i].state = .loading; sections[i].items = CardItemList(); sections[i].reasons = [:]; sections[i].unresolved = [] }
        info = nil
        guard DeckAnalysisController.allowsNetwork else {
            for i in sections.indices { sections[i].state = .offline }
            return
        }
        let store = DeckStore.shared(for: container)
        let writer = CardMetaWriter.shared(for: container)
        loadTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let result = await Self.combos(for: item, store: store, writer: writer)
                    await self.apply(result, to: "combos")
                }
                group.addTask {
                    let (result, info, commander) = await Self.edhrec(for: item, store: store, writer: writer)
                    await self.apply(result, to: "edhrec")
                    await self.set(info: info, commander: commander)
                }
                group.addTask {
                    let result = await Self.theme(for: item, identity: identity, store: store)
                    await self.apply(result, to: "theme")
                }
            }
        }
    }

    private func set(info: EDHRECCardInfo?, commander: Bool) {
        self.info = info
        isCommanderPage = commander
    }

    /// Built off the main actor by the loaders, so not actor-isolated.
    nonisolated private struct Loaded: Sendable {
        var items: [CardItem] = []
        var reasons: [String: CardReason] = [:]
        var unresolved: [String] = []
        var state: State = .ready
    }

    private func apply(_ loaded: Loaded, to id: String) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[i].items = CardItemList(loaded.items)
        sections[i].reasons = loaded.reasons
        sections[i].unresolved = loaded.unresolved
        sections[i].state = loaded.state == .ready && loaded.items.isEmpty && loaded.unresolved.isEmpty ? .empty : loaded.state
    }

    // MARK: Combos

    nonisolated private static func combos(for item: CardItem, store: DeckStore, writer: CardMetaWriter) async -> Loaded {
        let key = "variants-" + DiskJSONCache.hash(CardReading.frontName(item.name))
        var variants = await cache.value([SpellbookVariant].self, key: key, ttl: ttl)
        if variants == nil {
            guard let fetched = try? await CommanderSpellbookClient.shared.variants(using: item.name) else { return Loaded(state: .unavailable) }
            await cache.store(fetched, key: key)
            variants = fetched
        }
        let front = CardReading.frontName
        let me = front(item.name)
        // Partners, most played combo first; each partner once, with the
        // combo's result and how many combos it shares with this card.
        var order: [String] = []
        var byOracle: [String: (name: String, results: [String], count: Int)] = [:]
        var unresolvedNames: [String] = []
        for v in (variants ?? []).sorted(by: { ($0.popularity ?? 0) > ($1.popularity ?? 0) }) {
            for use in v.uses where front(use.card.name) != me {
                guard let oracle = use.card.oracleId else {
                    if !unresolvedNames.contains(use.card.name) { unresolvedNames.append(use.card.name) }
                    continue
                }
                if var entry = byOracle[oracle] {
                    entry.count += 1
                    for r in v.results where !entry.results.contains(r) { entry.results.append(r) }
                    byOracle[oracle] = entry
                } else {
                    byOracle[oracle] = (use.card.name, v.results, 1)
                    order.append(oracle)
                }
            }
        }
        let names = byOracle.mapValues(\.name)
        var resolved = (try? await store.items(oracleIDs: order, names: names)) ?? [:]
        let missing = order.filter { resolved[$0] == nil }.compactMap { byOracle[$0]?.name }
        if !missing.isEmpty {
            await EDHRECSynergyLoader.fetchMissing(names: missing, writer: writer)
            if let again = try? await store.items(oracleIDs: order, names: names) { resolved.merge(again) { a, _ in a } }
        }
        var out = Loaded()
        for oracle in order.prefix(40) {
            guard let entry = byOracle[oracle] else { continue }
            if let card = resolved[oracle] {
                out.items.append(card)
                out.reasons[card.id] = .comboResult(entry.results.first)
            } else {
                out.unresolved.append(entry.name)
            }
        }
        out.unresolved.append(contentsOf: unresolvedNames)
        return out
    }

    // MARK: EDHREC

    nonisolated private static func edhrec(for item: CardItem, store: DeckStore, writer: CardMetaWriter) async -> (Loaded, EDHRECCardInfo?, Bool) {
        let result = await EDHRECSynergyLoader.picks(for: item, limit: 40, store: store, writer: writer)
        guard result.available else { return (Loaded(state: .unavailable), nil, false) }
        var out = Loaded()
        for pick in result.picks {
            out.items.append(pick.card)
            out.reasons[pick.card.id] = pick.reason
        }
        out.unresolved = result.unresolved
        return (out, result.info, result.isCommanderPage)
    }

    // MARK: Theme

    nonisolated private static func theme(for item: CardItem, identity: [ManaColor]?, store: DeckStore) async -> Loaded {
        guard let query = SynergyQuery.scryfall(for: item, identity: identity) else { return Loaded(state: .empty) }
        let key = "theme-" + DiskJSONCache.hash(query)
        var cards = await cache.value([ScryfallCard].self, key: key, ttl: 24 * 3600)
        if cards == nil {
            guard let page = try? await ScryfallClient.shared.search(query: query, unique: "cards", order: "edhrec", direction: "asc") else {
                return Loaded(state: .unavailable)
            }
            let slice = Array(page.cards.prefix(30))
            await cache.store(slice, key: key)
            cards = slice
        }
        let owned = (try? await store.ownedCopiesByKey()) ?? [:]
        let mine = CardReading(item, identity: identity ?? ManaColor.allCases)
        var out = Loaded()
        for card in cards ?? [] {
            let ci = CardItem(scryfallCard: card, owned: (owned[card.bestOracleID ?? card.id] ?? 0) > 0)
            out.items.append(ci)
            let theirs = CardReading(ci, identity: identity ?? ManaColor.allCases)
            let shared = SynergyQuery.themes(of: mine).filter { theirs.mechanics.contains($0) }
            out.reasons[ci.id] = .theme(shared.first ?? SynergyQuery.themes(of: mine).first ?? "Same theme")
        }
        return out
    }
}

/// The Scryfall query behind "shares a theme": the first few (most
/// specific) mechanics a card's text touches, as an OR of their terms,
/// the card itself excluded, within a colour identity when one is given.
nonisolated enum SynergyQuery {
    static let maxThemes = 3

    /// The mechanics that make a theme, most specific first (the order of
    /// `DeckMechanic.all`); "card draw" and "entering the battlefield"
    /// describe too much of Magic to count on their own.
    static func themes(of reading: CardReading) -> [String] {
        let broad: Set<String> = ["card draw", "entering the battlefield", "exile", "attacking"]
        let specific = DeckMechanic.all.map(\.label).filter { reading.textMechanics.contains($0) && !broad.contains($0) }
        if !specific.isEmpty { return Array(specific.prefix(maxThemes)) }
        return Array(DeckMechanic.all.map(\.label).filter { reading.textMechanics.contains($0) }.prefix(1))
    }

    static func scryfall(for item: CardItem, identity: [ManaColor]?) -> String? {
        let reading = CardReading(item, identity: identity ?? ManaColor.allCases)
        let labels = themes(of: reading)
        guard !labels.isEmpty else { return nil }
        let terms = labels.compactMap { DeckMechanic.byLabel[$0]?.scryfall }
        var parts: [String] = []
        parts.append(terms.count == 1 ? terms[0] : "(" + terms.joined(separator: " or ") + ")")
        let name = CardReading.frontName(item.name).replacingOccurrences(of: "\"", with: "")
        parts.append("-name:\"\(name)\"")
        if let identity {
            parts.append(identity.isEmpty ? "id<=c" : "id<=" + identity.map { $0.rawValue.lowercased() }.joined())
        }
        parts.append("-is:funny")
        parts.append("f:commander")
        return parts.joined(separator: " ")
    }
}
