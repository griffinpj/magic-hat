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
    private(set) var isLoaded = false
    private var loadTask: Task<Void, Never>?

    /// Each list's names folded once (case and diacritics), in the list's
    /// order, so a keystroke's match is a plain prefix/contains over
    /// Swift strings. Matching with `range(of:options:)` ran a locale-aware
    /// search over ~10k artist names on the main thread per keystroke.
    private var typeKeys: [String] = []
    private var keywordKeys: [String] = []
    private var artistKeys: [String] = []
    private var setKeys: [String] = []

    /// Loads everything once; failures leave that list empty (free text
    /// still works) and a later call retries.
    func load() async {
        if isLoaded { return }
        if let loadTask { await loadTask.value; return }
        let task = Task { await fetch() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func fetch() async {
        let cache = ScryfallCatalogCache.shared
        var typeEntries: [TypeEntry] = []
        for catalog in ScryfallCatalog.typeLine {
            if let names = try? await cache.catalog(catalog) {
                typeEntries.append(contentsOf: names.map { TypeEntry(name: $0, catalog: catalog) })
            }
        }
        var words: [String] = []
        for catalog in [ScryfallCatalog.keywordAbilities, .keywordActions, .abilityWords] {
            if let names = try? await cache.catalog(catalog) { words.append(contentsOf: names) }
        }
        let artistNames = (try? await cache.catalog(.artistNames)) ?? []
        let setList = ((try? await cache.sets()) ?? []).filter { !Self.hiddenSetTypes.contains($0.setType ?? "") }
        // Folding ~12k names is a few tens of milliseconds: off the main actor.
        let keys = await Task.detached(priority: .userInitiated) {
            (typeEntries.map { Self.fold($0.name) }, words.map(Self.fold), artistNames.map(Self.fold), setList.map { Self.fold($0.displayName) })
        }.value
        types = typeEntries; typeKeys = keys.0
        keywords = words; keywordKeys = keys.1
        artists = artistNames; artistKeys = keys.2
        sets = setList; setKeys = keys.3
        isLoaded = !types.isEmpty || !sets.isEmpty
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
