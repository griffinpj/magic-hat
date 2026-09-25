//
//  AnalysisSignalSource.swift
//  magic-hat
//
//  The lists the deck analysis reads from outside, each kept on disk and
//  refreshed on its own schedule:
//
//  - Game Changers: Scryfall's `is:gamechanger` (the official list, ~50
//    cards, one page). Daily — Wizards adds and removes cards, and a deck
//    rated against an old list is quietly wrong.
//  - Oracle tags: Scryfall's Tagger lists (`otag:ramp`, `otag:tutor`, …),
//    thousands of cards over a dozen pages each. Weekly, and a few pages
//    per sitting: each page waits its turn in the search rate limit, so a
//    whole list at once would sit ahead of the user's own search. A list
//    resumes where it stopped; until it is in, the text patterns stand in.
//
//  An actor so two screens asking at once share one fetch.
//

import Foundation

actor AnalysisSignalSource {
    static let shared = AnalysisSignalSource()

    nonisolated private struct TagList: Codable, Sendable {
        var ids: [String]
        /// Where a partial fetch continues; nil once the list is whole.
        var next: String?
        var pending: [String]
    }

    private let cache = DiskJSONCache(folder: "AnalysisSignals")
    private var gameChangersTask: Task<[String: String]?, Never>?
    private var tagTask: Task<Void, Never>?
    private let client: ScryfallClient

    static let gameChangersTTL: TimeInterval = 24 * 3600
    static let tagsTTL: TimeInterval = 7 * 24 * 3600
    /// Search pages per sitting for a tag list.
    static let tagPagesPerSitting = 6

    init(client: ScryfallClient = .shared) {
        self.client = client
    }

    // MARK: Game changers

    /// Oracle id → name. The cached list if fresh, else fetched (when
    /// `allowNetwork`); a stale list is better than none when the fetch fails.
    func gameChangers(allowNetwork: Bool) async -> [String: String]? {
        if let fresh = await cache.value([String: String].self, key: "game-changers", ttl: Self.gameChangersTTL) { return fresh }
        let stale = await cache.stale([String: String].self, key: "game-changers")?.value
        guard allowNetwork else { return stale }
        if let task = gameChangersTask { return await task.value ?? stale }
        let task = Task<[String: String]?, Never> { [client, cache] in
            guard let page = try? await client.oracleIndex(query: "is:gamechanger", maxPages: 4), !page.index.isEmpty else { return nil }
            await cache.store(page.index, key: "game-changers")
            return page.index
        }
        gameChangersTask = task
        let result = await task.value
        gameChangersTask = nil
        return result ?? stale
    }

    // MARK: Oracle tags

    /// Every complete tag list on disk, fresh or not (a week-old list of
    /// what counts as ramp is still right). Does not fetch.
    func tagLists() async -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for tag in DeckAnalysisSignals.allTags {
            if let list = await cache.stale(TagList.self, key: "otag-\(tag)")?.value, !list.ids.isEmpty {
                out[tag] = Set(list.ids)
            }
        }
        return out
    }

    /// Advances the stalest (or unfinished) tag list by a few pages. One
    /// refresh at a time; returns when this sitting's pages are in.
    func refreshTags() async {
        if let tagTask { await tagTask.value; return }
        let task = Task { await self.refreshOneTag() }
        tagTask = task
        await task.value
        tagTask = nil
    }

    private func refreshOneTag() async {
        var stalest: (tag: String, age: TimeInterval)?
        for tag in DeckAnalysisSignals.allTags {
            let key = "otag-\(tag)"
            let entry = await cache.stale(TagList.self, key: key)
            let partial = entry?.value.next != nil
            let age: TimeInterval = (entry == nil || partial) ? .greatestFiniteMagnitude : Date().timeIntervalSince(entry!.fetchedAt)
            if age > Self.tagsTTL, age > (stalest?.age ?? -1) { stalest = (tag, age) }
        }
        guard let (tag, _) = stalest else { return }
        let key = "otag-\(tag)"
        let existing = await cache.stale(TagList.self, key: key)?.value
        let resume = existing?.next.flatMap(URL.init(string:))
        var pending = resume != nil ? (existing?.pending ?? []) : []
        guard let page = try? await client.oracleIndex(query: "otag:\(tag)", maxPages: Self.tagPagesPerSitting, resume: resume) else { return }
        pending.append(contentsOf: page.index.keys)
        if let next = page.next {
            // Out of pages for this sitting: keep what is fetched and where
            // to continue; the old list (if any) stays in use meanwhile.
            await cache.store(TagList(ids: existing?.ids ?? [], next: next.absoluteString, pending: pending), key: key)
        } else if !pending.isEmpty {
            await cache.store(TagList(ids: Array(Set(pending)), next: nil, pending: []), key: key)
        }
    }
}
