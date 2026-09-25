//
//  DeckAnalysisController.swift
//  magic-hat
//
//  Runs the deck analysis for one deck and holds the result for its
//  screens: the local reading first (roles, sources, scores — from the
//  catalog's oracle text, no network, off the main actor), then the
//  outside signals as they land — Commander Spellbook's combos, Scryfall's
//  game changers and oracle tags, Recommander's meta scores — each
//  re-running the (cheap) analysis and republishing. Then the swap table
//  and the recommendations over the collection's spare cards.
//
//  Answers are cached per list on disk (DiskJSONCache), so re-opening a
//  deck is a read, not a round of requests. Nothing here is main-thread
//  work: the analysis and the planner run in detached tasks and only the
//  assignments land on the main actor. One controller per deck, kept
//  while the app runs, so leaving and returning shows what was there.
//

import Foundation
import Observation
import SwiftData
import os

@MainActor
@Observable
final class DeckAnalysisController {
    enum Phase: Equatable {
        case idle, analyzing, ready
    }

    /// Where an outside source stands for the current list.
    enum SourceState: Equatable {
        case pending, done, unavailable, offline
    }

    let deckID: UUID
    private(set) var analysis: DeckAnalysis?
    private(set) var plan: DeckPlan?
    private(set) var phase: Phase = .idle
    private(set) var isPlanning = false
    private(set) var combos: SourceState = .pending
    private(set) var gameChangers: SourceState = .pending
    private(set) var meta: SourceState = .pending
    /// EDHREC's whole list for the commander, best first — what the add
    /// sheet's Recommended scope leads with. Kept while the commander is
    /// the same, whatever else the list does.
    private(set) var commanderPicks: [SynergyPick] = []
    private(set) var synergies: SourceState = .pending
    /// Bumped when `commanderPicks` changes, for views to key on.
    private(set) var synergyVersion = 0
    private var picksFor: String?
    private var picksTask: Task<Void, Never>?
    /// The list the current analysis describes.
    private(set) var listHash = ""

    private var signals = DeckAnalysisSignals.none
    private var readings: [String: CardReading] = [:]
    private var snapshot: DeckSnapshot?
    private var runTask: Task<Void, Never>?
    private var planTask: Task<Void, Never>?
    private var generation = 0
    private var plannedFor: (hash: String, collection: Int, signals: Int)?
    private var planningFor: (hash: String, collection: Int, signals: Int)?
    /// The collection's spare cards, kept for the collection revision they
    /// were read at: three signals landing meant three full reads.
    private var collectionCandidates: (revision: Int, cards: [DeckSearchResult])?
    /// Candidate readings by card id, kept across replans — the regexes
    /// over a thousand spare cards are the plan's cost, and the cards do
    /// not change between one signal landing and the next. Dropped when
    /// the tag lists change, since they change what a reading says.
    private var candidateReadings: [String: CardReading] = [:]
    private var candidateReadingsTags = ""
    private var signalVersion = 0

    private static let cache = DiskJSONCache(folder: "DeckAnalysis")
    private static let log = Logger(subsystem: "magic-hat", category: "analysis")
    static let combosTTL: TimeInterval = 30 * 24 * 3600
    static let metaTTL: TimeInterval = 7 * 24 * 3600

    @MainActor private static var instances: [UUID: DeckAnalysisController] = [:]

    static func shared(for deckID: UUID) -> DeckAnalysisController {
        if let existing = instances[deckID] { return existing }
        let controller = DeckAnalysisController(deckID: deckID)
        instances[deckID] = controller
        return controller
    }

    init(deckID: UUID) {
        self.deckID = deckID
    }

    /// Whether anything outside may be asked. Never in a seeded UI test.
    static var allowsNetwork: Bool { !UITestSeed.isSeededRun }

    var sourcesLine: String {
        var bits: [String] = []
        bits.append(gameChangers == .done ? "Game changers from Scryfall" : "Game changers not checked")
        if let analysis, analysis.tagsChecked { bits.append("roles from its oracle tags") } else { bits.append("roles from oracle text") }
        bits.append(combos == .done ? "combos from Commander Spellbook" : "combos not checked")
        if meta == .done { bits.append("meta scores from Recommander") }
        return bits.joined(separator: " · ") + "."
    }

    // MARK: Running

    /// Analyses `snapshot` if its list changed (or nothing has run yet),
    /// and re-plans against the collection when either changed.
    func refresh(snapshot: DeckSnapshot, container: ModelContainer) {
        let hash = Self.hash(of: snapshot)
        let collectionRevision = CollectionChangeTracker.shared.revision
        self.snapshot = snapshot
        if hash != listHash || phase == .idle {
            listHash = hash
            run(snapshot: snapshot, hash: hash, container: container)
        } else if let plannedFor, plannedFor.hash == hash, plannedFor.collection == collectionRevision, plannedFor.signals == signalVersion {
            return
        } else if analysis != nil {
            replan(container: container)
        }
    }

    private func run(snapshot: DeckSnapshot, hash: String, container: ModelContainer) {
        runTask?.cancel()
        planTask?.cancel()
        generation += 1
        let gen = generation
        phase = .analyzing
        combos = .pending
        gameChangers = .pending
        meta = .pending
        signals = .none
        // The old plan stays on screen until the new one lands: a list that
        // turned into a spinner on every add lost the user's place (and
        // the tap that was in flight).
        plannedFor = nil
        let allowNetwork = Self.allowsNetwork
        let isCommander = snapshot.format.hasCommander && !snapshot.commanders.isEmpty

        runTask = Task { [weak self] in
            guard let self else { return }
            // 1. What is already on disk: tag lists and the game-changer list.
            let source = AnalysisSignalSource.shared
            async let tags = source.tagLists()
            async let gcCached = Self.cachedGameChangers()
            var sig = DeckAnalysisSignals.none
            sig.tags = await tags
            sig.gameChangers = await gcCached
            let tagsKey = sig.tags.keys.sorted().map { "\($0):\(sig.tags[$0]!.count)" }.joined(separator: ",")
            if tagsKey != self.candidateReadingsTags { self.candidateReadings = [:]; self.candidateReadingsTags = tagsKey }
            if let cached = await Self.cache.value(DeckComboSet.self, key: "combos-\(hash)", ttl: Self.combosTTL) { sig.combos = cached }
            if let cached = await Self.cache.value(MetaCache.self, key: "meta-\(hash)", ttl: Self.metaTTL) { sig.meta = cached.scores; sig.metaNames = cached.names }
            guard !Task.isCancelled, gen == self.generation else { return }
            await self.publish(snapshot: snapshot, signals: sig, generation: gen)
            self.combos = sig.combos != nil ? .done : (allowNetwork && isCommander ? .pending : (isCommander ? .offline : .unavailable))
            self.gameChangers = sig.gameChangers != nil ? .done : (allowNetwork ? .pending : .offline)
            self.meta = sig.meta != nil ? .done : (allowNetwork && isCommander ? .pending : (isCommander ? .offline : .unavailable))
            self.phase = .ready
            self.replan(container: container)
            self.loadCommanderPicks(snapshot: snapshot, container: container, allowNetwork: allowNetwork)

            guard allowNetwork else { return }
            // 2. The outside signals, concurrently; each republishes as it lands.
            await withTaskGroup(of: Void.self) { group in
                if sig.gameChangers == nil {
                    group.addTask { [weak self] in
                        let list = await source.gameChangers(allowNetwork: true)
                        await self?.landed(gameChangers: list, generation: gen, container: container)
                    }
                }
                if isCommander, sig.combos == nil {
                    group.addTask { [weak self] in
                        let set = await Self.fetchCombos(snapshot: snapshot)
                        if let set { await Self.cache.store(set, key: "combos-\(hash)") }
                        await self?.landed(combos: set, generation: gen, container: container)
                    }
                }
                if isCommander, sig.meta == nil, snapshot.playedItems.count >= 10 {
                    group.addTask { [weak self] in
                        let meta = await Self.fetchMeta(snapshot: snapshot)
                        if let meta { await Self.cache.store(meta, key: "meta-\(hash)") }
                        await self?.landed(meta: meta, generation: gen, container: container)
                    }
                }
            }
            // 3. Move one oracle-tag list along, after everything the screen
            //    is waiting for; a fresh list re-reads the deck next time.
            Task(priority: .utility) { await source.refreshTags() }
        }
    }

    /// The commander's EDHREC list, once per commander: a new list with
    /// the same commander keeps what it has.
    private func loadCommanderPicks(snapshot: DeckSnapshot, container: ModelContainer, allowNetwork: Bool) {
        guard snapshot.format.hasCommander, let commander = snapshot.commanders.first?.card else {
            commanderPicks = []; picksFor = nil; synergies = .unavailable; synergyVersion += 1; return
        }
        if picksFor == commander.scryfallID, synergies != .pending { return }
        guard allowNetwork else { synergies = .offline; return }
        picksFor = commander.scryfallID
        synergies = .pending
        picksTask?.cancel()
        let store = DeckStore.shared(for: container)
        let writer = CardMetaWriter.shared(for: container)
        picksTask = Task { [weak self] in
            let result = await EDHRECSynergyLoader.picks(for: commander, limit: nil, store: store, writer: writer)
            guard let self, !Task.isCancelled, self.picksFor == commander.scryfallID else { return }
            self.commanderPicks = result.picks
            self.synergies = result.available ? .done : .unavailable
            self.synergyVersion += 1
        }
    }

    private func landed(gameChangers list: [String: String]?, generation gen: Int, container: ModelContainer) async {
        guard gen == generation else { return }
        gameChangers = list != nil ? .done : .unavailable
        guard let list, let snapshot else { return }
        signals.gameChangers = list
        signalVersion += 1
        await publish(snapshot: snapshot, signals: signals, generation: gen)
        replan(container: container)
    }

    private func landed(combos set: DeckComboSet?, generation gen: Int, container: ModelContainer) async {
        guard gen == generation else { return }
        combos = set != nil ? .done : .unavailable
        guard let set, let snapshot else { return }
        signals.combos = set
        signalVersion += 1
        await publish(snapshot: snapshot, signals: signals, generation: gen)
        replan(container: container)
    }

    private func landed(meta cached: MetaCache?, generation gen: Int, container: ModelContainer) async {
        guard gen == generation else { return }
        meta = cached != nil ? .done : .unavailable
        guard let cached, let snapshot else { return }
        signals.meta = cached.scores
        signals.metaNames = cached.names
        signalVersion += 1
        await publish(snapshot: snapshot, signals: signals, generation: gen)
        replan(container: container)
    }

    /// Reads the deck with `signals` off the main actor and publishes.
    private func publish(snapshot: DeckSnapshot, signals: DeckAnalysisSignals, generation gen: Int) async {
        let (result, readings) = await Task.detached(priority: .userInitiated) { () -> (DeckAnalysis, [String: CardReading]) in
            let readings = DeckAnalysis.readings(for: snapshot.playedItems, identity: snapshot.identity, tags: signals.tags)
            return (DeckAnalysis.compute(snapshot: snapshot, signals: signals, readings: readings), readings)
        }.value
        guard gen == generation else { return }
        self.signals = signals
        self.readings = readings
        self.analysis = result
    }

    // MARK: Planning

    /// The recommendations and the swap table, against the collection's
    /// spare cards plus what the meta and the near-miss combos name.
    private func replan(container: ModelContainer) {
        guard let snapshot, let analysis else { return }
        let hash = listHash
        let collectionRevision = CollectionChangeTracker.shared.revision
        let version = signalVersion
        let gen = generation
        let signals = self.signals
        let readings = self.readings
        // Two screens refetch on the same tracker bump; one plan serves both.
        if let planningFor, planningFor == (hash, collectionRevision, version), planTask != nil { return }
        planTask?.cancel()
        planningFor = (hash, collectionRevision, version)
        isPlanning = true
        let store = DeckStore.shared(for: container)
        let rows = CollectionStore.shared(for: container)
        let stamp = StoreStamp.current
        let writer = CardMetaWriter.shared(for: container)
        let allowNetwork = Self.allowsNetwork
        let cachedCollection = collectionCandidates?.revision == collectionRevision ? collectionCandidates?.cards : nil
        let knownReadings = candidateReadings
        planTask = Task { [weak self] in
            let t0 = ContinuousClock.now
            let owned: [DeckSearchResult]
            if let cachedCollection {
                owned = cachedCollection
            } else {
                // The rows the Collections tab built for this stamp, when it
                // has; grouped off the main actor.
                let cards = (try? await rows.ownedCards(stamp: stamp)) ?? []
                owned = await Task.detached(priority: .userInitiated) { DeckStore.candidates(from: cards) }.value
                guard let self, !Task.isCancelled else { return }
                self.collectionCandidates = (collectionRevision, owned)
            }
            let candidates = await Self.candidates(snapshot: snapshot, analysis: analysis, signals: signals, owned: owned,
                                                  store: store, writer: writer, allowNetwork: allowNetwork)
            guard !Task.isCancelled else { return }
            let (plan, fresh) = await Task.detached(priority: .userInitiated) { () -> (DeckPlan, [String: CardReading]) in
                var fresh: [String: CardReading] = [:]
                var all = knownReadings
                for c in candidates where all[c.card.id] == nil {
                    let r = CardReading(c.card, identity: snapshot.identity, tags: signals.tags)
                    all[c.card.id] = r
                    fresh[c.card.id] = r
                }
                let plan = DeckPlan.plan(snapshot: snapshot, analysis: analysis, signals: signals, candidates: candidates,
                                         readings: readings, candidateReadings: all)
                return (plan, fresh)
            }.value
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            let elapsed = ContinuousClock.now - t0
            Self.log.notice("plan: \(candidates.count) candidates, \(fresh.count) read fresh, \(cachedCollection == nil ? "collection fetched" : "collection cached"), \(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)ms")
            self.candidateReadings.merge(fresh) { _, new in new }
            self.plan = plan
            self.plannedFor = (hash, collectionRevision, version)
            self.planningFor = nil
            self.planTask = nil
            self.isPlanning = false
        }
    }

    /// Spare cards in the collection (one per card, copies summed), the
    /// meta's picks and the missing pieces of one-card-away combos, as
    /// CardItems from the catalog. A name the catalog lacks is looked up
    /// on Scryfall once and kept. `@concurrent`: a nonisolated async
    /// function runs on its caller's actor, and the caller is the main
    /// actor — this loop over every spare card in the collection ran there.
    @concurrent
    nonisolated private static func candidates(snapshot: DeckSnapshot, analysis: DeckAnalysis, signals: DeckAnalysisSignals,
                                               owned: [DeckSearchResult], store: DeckStore, writer: CardMetaWriter,
                                               allowNetwork: Bool) async -> [DeckCandidate] {
        var out: [DeckCandidate] = []
        var seen = Set<String>()
        var ownedByKey: [String: Int] = [:]
        for c in owned {
            let key = c.card.oracleID ?? c.card.scryfallID
            ownedByKey[key] = c.ownedCopies
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(DeckCandidate(card: c.card, ownedCopies: c.ownedCopies, metaScore: c.card.oracleID.flatMap { signals.meta?[$0] }))
        }
        let metaOracles = (signals.meta ?? [:]).keys.filter { !seen.contains($0) }
        if !metaOracles.isEmpty, let items = try? await store.items(oracleIDs: Array(metaOracles), names: signals.metaNames) {
            for (oracle, card) in items where !seen.contains(oracle) {
                seen.insert(oracle)
                out.append(DeckCandidate(card: card, ownedCopies: ownedByKey[oracle] ?? 0, metaScore: signals.meta?[oracle]))
            }
        }
        let front = CardReading.frontName
        let inDeck = Set(snapshot.playedItems.map { front($0.card.name) })
        let named = Set(out.map { front($0.card.name) })
        let missing = Array(Set(analysis.nearCombos.compactMap(\.missing)))
            .filter { !inDeck.contains(front($0)) && !named.contains(front($0)) }
        if !missing.isEmpty {
            var found = (try? await store.items(names: missing)) ?? [:]
            let unresolved = missing.filter { found[$0] == nil }
            if allowNetwork, !unresolved.isEmpty,
               let fetched = try? await ScryfallClient.shared.collection(identifiers: unresolved.prefix(75).map { ScryfallCardIdentifier(name: $0) }) {
                try? await writer.apply(cards: fetched.data, linkEntries: false)
                if let again = try? await store.items(names: unresolved) { found.merge(again) { a, _ in a } }
            }
            for (_, card) in found {
                let key = card.oracleID ?? card.scryfallID
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(DeckCandidate(card: card, ownedCopies: ownedByKey[key] ?? 0, metaScore: card.oracleID.flatMap { signals.meta?[$0] }))
            }
        }
        return out
    }

    // MARK: Fetching

    nonisolated private static func cachedGameChangers() async -> [String: String]? {
        await AnalysisSignalSource.shared.gameChangers(allowNetwork: false)
    }

    @concurrent
    nonisolated private static func fetchCombos(snapshot: DeckSnapshot) async -> DeckComboSet? {
        let commanders = snapshot.commanders.map(\.card.name)
        let main = snapshot.sections.flatMap(\.items).map { (name: $0.card.name, quantity: $0.quantity) }
        guard let results = try? await CommanderSpellbookClient.shared.findCombos(commanders: commanders, main: main) else { return nil }
        let have = Set(snapshot.playedItems.map { CardReading.frontName($0.card.name) })
        return CommanderSpellbookClient.comboSet(results, have: have)
    }

    /// Recommander's answer as cached: scores and names by oracle id.
    nonisolated struct MetaCache: Codable, Sendable {
        let scores: [String: Double]
        let names: [String: String]
    }

    @concurrent
    nonisolated private static func fetchMeta(snapshot: DeckSnapshot) async -> MetaCache? {
        guard let commander = snapshot.commanders.first?.card.name else { return nil }
        let partner = snapshot.commanders.dropFirst().first?.card.name
        let deck = snapshot.sections.flatMap(\.items).map(\.card.name)
        guard let recs = try? await RecommanderClient.shared.recommend(commander: commander, partner: partner, deck: deck) else { return nil }
        var scores: [String: Double] = [:]
        var names: [String: String] = [:]
        for rec in recs { scores[rec.oracleID] = (rec.score * 1000).rounded() / 1000; names[rec.oracleID] = rec.name }
        return MetaCache(scores: scores, names: names)
    }

    /// The list as a stable key: every played row's printing, count and
    /// board, sorted, hashed.
    nonisolated static func hash(of snapshot: DeckSnapshot) -> String {
        let lines = snapshot.playedItems.map { "\($0.card.scryfallID):\($0.quantity):\($0.board.rawValue)" }.sorted()
        return DiskJSONCache.hash(lines.joined(separator: ","))
    }
}
