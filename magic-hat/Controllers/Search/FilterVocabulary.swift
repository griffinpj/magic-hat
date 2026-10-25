//
//  FilterVocabulary.swift
//  magic-hat
//
//  The word lists the filter token fields suggest from — every type and
//  subtype, keywords, artists, sets — loaded once from ScryfallCatalogCache
//  and matched in memory as the user types. Prefix matches come first, then
//  contains, so "dra" offers Dragon before Hydra.
//

import Foundation
import Observation

@MainActor
@Observable
final class FilterVocabulary {
    static let shared = FilterVocabulary()

    struct TypeEntry: Hashable, Identifiable {
        let name: String
        let catalog: ScryfallCatalog
        var id: String { name }
    }

    private(set) var types: [TypeEntry] = []
    private(set) var keywords: [String] = []
    private(set) var artists: [String] = []
    private(set) var sets: [ScryfallSet] = []
    /// Every list is in.
    private(set) var isLoaded = false
    private var loadTask: Task<Void, Never>?
    /// What each catalog returned, kept across attempts so a retry asks
    /// only for the lists that failed.
    private var loadedCatalogs: [ScryfallCatalog: [String]] = [:]
    private var loadedSets: [ScryfallSet]?
    /// When the last attempt that left something missing ran. Offline, the
    /// form appearing used to refire all eleven requests each time.
    private var lastFailedAttempt: Date?
    /// How long after a partial load before the form's next appearance
    /// tries the missing lists again.
    static let retryInterval: TimeInterval = 30

    /// Each list's names folded once (case and diacritics), in the list's
    /// order, so a keystroke's match is a plain prefix/contains over
    /// Swift strings. Matching with `range(of:options:)` ran a locale-aware
    /// search over ~10k artist names on the main thread per keystroke.
    private var typeKeys: [String] = []
    private var keywordKeys: [String] = []
    private var artistKeys: [String] = []
    private var setKeys: [String] = []

    private static let keywordCatalogs: [ScryfallCatalog] = [.keywordAbilities, .keywordActions, .abilityWords]
    private static let allCatalogs: [ScryfallCatalog] = ScryfallCatalog.typeLine + keywordCatalogs + [.artistNames]

    /// Loads everything once; a list that fails stays empty (free text
    /// still works) and a later call retries just the lists still missing
    /// — not while offline, and not within `retryInterval` of the last
    /// try.
    func load() async {
        if isLoaded { return }
        if let loadTask { await loadTask.value; return }
        if let lastFailedAttempt {
            guard NetworkMonitor.shared.isConnected,
                  Date().timeIntervalSince(lastFailedAttempt) >= Self.retryInterval else { return }
        }
        let task = Task { await fetch() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func fetch() async {
        let cache = ScryfallCatalogCache.shared
        let activity = DataActivity.shared
        activity.begin(.vocabularies)
        for catalog in Self.allCatalogs where loadedCatalogs[catalog] == nil {
            if let names = try? await cache.catalog(catalog) { loadedCatalogs[catalog] = names }
        }
        if loadedSets == nil, let list = try? await cache.sets() {
            loadedSets = list.filter { !Self.hiddenSetTypes.contains($0.setType ?? "") }
        }
        let typeEntries = ScryfallCatalog.typeLine.flatMap { catalog in
            (loadedCatalogs[catalog] ?? []).map { TypeEntry(name: $0, catalog: catalog) }
        }
        let words = Self.keywordCatalogs.flatMap { loadedCatalogs[$0] ?? [] }
        let artistNames = loadedCatalogs[.artistNames] ?? []
        let setList = loadedSets ?? []
        // Folding ~12k names is a few tens of milliseconds: off the main actor.
        let keys = await Task.detached(priority: .userInitiated) {
            (typeEntries.map { Self.fold($0.name) }, words.map(Self.fold), artistNames.map(Self.fold), setList.map { Self.fold($0.displayName) })
        }.value
        let total = typeEntries.count + words.count + artistNames.count
        let complete = loadedSets != nil && Self.allCatalogs.allSatisfy { loadedCatalogs[$0] != nil }
        activity.end(.vocabularies, count: total,
                     note: total == 0 ? "Nothing loaded" : "\(typeEntries.count.formatted()) types, \(words.count.formatted()) keywords, \(artistNames.count.formatted()) artists",
                     failed: !complete)
        types = typeEntries; typeKeys = keys.0
        keywords = words; keywordKeys = keys.1
        artists = artistNames; artistKeys = keys.2
        sets = setList; setKeys = keys.3
        isLoaded = complete
        lastFailedAttempt = complete ? nil : Date()
    }

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Products, not tokens/promos/memorabilia.
    private static let hiddenSetTypes: Set<String> = ["token", "promo", "memorabilia", "minigame"]

    // MARK: Matching

    func typeMatches(_ query: String, limit: Int = 6) -> [TypeEntry] {
        Self.rank(types, keys: typeKeys, query: query, limit: limit)
    }

    func keywordMatches(_ query: String, limit: Int = 6) -> [String] {
        Self.rank(keywords, keys: keywordKeys, query: query, limit: limit)
    }

    func artistMatches(_ query: String, limit: Int = 6) -> [String] {
        Self.rank(artists, keys: artistKeys, query: query, limit: limit)
    }

    func setMatches(_ query: String, limit: Int = 6) -> [ScryfallSet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let code = q.lowercased()
        let byCode = sets.filter { $0.code == code }
        let rest = Self.rank(sets, keys: setKeys, query: q, limit: limit)
        var out = byCode
        for s in rest where !out.contains(s) { out.append(s) }
        return Array(out.prefix(limit))
    }

    private static func rank<T>(_ items: [T], keys: [String], query: String, limit: Int) -> [T] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty, keys.count == items.count else { return [] }
        var prefix: [T] = [], contains: [T] = []
        for (item, key) in zip(items, keys) {
            if key.hasPrefix(q) {
                prefix.append(item)
            } else if key.contains(q) {
                contains.append(item)
            }
            if prefix.count >= limit { break }
        }
        return Array((prefix + contains).prefix(limit))
    }
}

// Read inside the detached fold above: opted out of the file's main-actor
// default so a plain value type's property is usable off the main actor.
nonisolated extension ScryfallSet {
    var displayName: String { name ?? code.uppercased() }
}
