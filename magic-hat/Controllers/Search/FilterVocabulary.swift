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
        types = typeEntries
        var words: [String] = []
        for catalog in [ScryfallCatalog.keywordAbilities, .keywordActions, .abilityWords] {
            if let names = try? await cache.catalog(catalog) { words.append(contentsOf: names) }
        }
        keywords = words
        artists = (try? await cache.catalog(.artistNames)) ?? []
        sets = ((try? await cache.sets()) ?? []).filter { !Self.hiddenSetTypes.contains($0.setType ?? "") }
        isLoaded = !types.isEmpty || !sets.isEmpty
    }

    /// Products, not tokens/promos/memorabilia.
    private static let hiddenSetTypes: Set<String> = ["token", "promo", "memorabilia", "minigame"]

    // MARK: Matching

    func typeMatches(_ query: String, limit: Int = 6) -> [TypeEntry] {
        Self.rank(types, query: query, key: \.name, limit: limit)
    }

    func keywordMatches(_ query: String, limit: Int = 6) -> [String] {
        Self.rank(keywords, query: query, key: \.self, limit: limit)
    }

    func artistMatches(_ query: String, limit: Int = 6) -> [String] {
        Self.rank(artists, query: query, key: \.self, limit: limit)
    }

    func setMatches(_ query: String, limit: Int = 6) -> [ScryfallSet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let byCode = sets.filter { $0.code.caseInsensitiveCompare(q) == .orderedSame }
        let rest = Self.rank(sets, query: q, key: \.displayName, limit: limit)
        var out = byCode
        for s in rest where !out.contains(s) { out.append(s) }
        return Array(out.prefix(limit))
    }

    private static func rank<T>(_ items: [T], query: String, key: KeyPath<T, String>, limit: Int) -> [T] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var prefix: [T] = [], contains: [T] = []
        for item in items {
            let name = item[keyPath: key]
            if name.range(of: q, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil {
                prefix.append(item)
            } else if name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                contains.append(item)
            }
            if prefix.count >= limit { break }
        }
        return Array((prefix + contains).prefix(limit))
    }
}

extension ScryfallSet {
    var displayName: String { name ?? code.uppercased() }
}
