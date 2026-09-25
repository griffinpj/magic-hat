//
//  ScryfallCatalogCache.swift
//  magic-hat
//
//  The vocabularies the filter pickers offer — card and creature types,
//  keyword abilities, artist names — and the set list, each fetched once
//  from Scryfall's /catalog and /sets endpoints and kept on disk for a week
//  (they change when a set releases, roughly monthly). Same shape as
//  PrintingsCache: memory, then disk, then network, with in-flight requests
//  de-duplicated so two pickers opening at once cost one call.
//

import Foundation

/// Scryfall /catalog names the pickers use.
nonisolated enum ScryfallCatalog: String, CaseIterable, Sendable {
    case supertypes
    case cardTypes = "card-types"
    case creatureTypes = "creature-types"
    case artifactTypes = "artifact-types"
    case enchantmentTypes = "enchantment-types"
    case landTypes = "land-types"
    case planeswalkerTypes = "planeswalker-types"
    case spellTypes = "spell-types"
    case battleTypes = "battle-types"
    case keywordAbilities = "keyword-abilities"
    case keywordActions = "keyword-actions"
    case abilityWords = "ability-words"
    case artistNames = "artist-names"

    var label: String {
        switch self {
        case .supertypes: return "Supertypes"
        case .cardTypes: return "Card Types"
        case .creatureTypes: return "Creature Types"
        case .artifactTypes: return "Artifact Types"
        case .enchantmentTypes: return "Enchantment Types"
        case .landTypes: return "Land Types"
        case .planeswalkerTypes: return "Planeswalker Types"
        case .spellTypes: return "Spell Types"
        case .battleTypes: return "Battle Types"
        case .keywordAbilities: return "Keyword Abilities"
        case .keywordActions: return "Keyword Actions"
        case .abilityWords: return "Ability Words"
        case .artistNames: return "Artists"
        }
    }

    /// The catalogs that make up a type line, in the order they read.
    static let typeLine: [ScryfallCatalog] = [
        .supertypes, .cardTypes, .creatureTypes, .artifactTypes, .enchantmentTypes,
        .landTypes, .planeswalkerTypes, .spellTypes, .battleTypes,
    ]
}

@MainActor
final class ScryfallCatalogCache {
    static let shared = ScryfallCatalogCache()

    static let ttl: TimeInterval = 7 * 24 * 3600

    nonisolated private struct Entry<T: Codable & Sendable>: Codable, Sendable {
        let value: T
        let fetchedAt: Date
    }

    private var catalogs: [ScryfallCatalog: Entry<[String]>] = [:]
    private var setList: Entry<[ScryfallSet]>?
    private var inFlightCatalogs: [ScryfallCatalog: Task<[String], Error>] = [:]
    private var inFlightSets: Task<[ScryfallSet], Error>?

    private let directory: URL
    private let fm = FileManager.default

    init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("ScryfallCatalogs", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func catalog(_ name: ScryfallCatalog) async throws -> [String] {
        if let entry = catalogs[name], isFresh(entry.fetchedAt) { return entry.value }
        if let entry: Entry<[String]> = await Self.read(fileURL(name.rawValue)), isFresh(entry.fetchedAt) {
            catalogs[name] = entry
            return entry.value
        }
        if let task = inFlightCatalogs[name] { return try await task.value }
        let task = Task { try await ScryfallClient.shared.catalog(name.rawValue) }
        inFlightCatalogs[name] = task
        defer { inFlightCatalogs[name] = nil }
        let value = try await task.value
        let entry = Entry(value: value, fetchedAt: Date())
        catalogs[name] = entry
        await Self.write(entry, to: fileURL(name.rawValue))
        return value
    }

    /// Every paper-or-digital set, newest first, as Scryfall orders them.
    func sets() async throws -> [ScryfallSet] {
        if let setList, isFresh(setList.fetchedAt) { return setList.value }
        if let entry: Entry<[ScryfallSet]> = await Self.read(fileURL("sets")), isFresh(entry.fetchedAt) {
            setList = entry
            return entry.value
        }
        if let task = inFlightSets { return try await task.value }
        let task = Task { try await ScryfallClient.shared.sets() }
        inFlightSets = task
        defer { inFlightSets = nil }
        let value = try await task.value
        let entry = Entry(value: value, fetchedAt: Date())
        setList = entry
        await Self.write(entry, to: fileURL("sets"))
        return value
    }

    // MARK: Disk

    private func isFresh(_ date: Date) -> Bool { Date().timeIntervalSince(date) < Self.ttl }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    // Reading and encoding a 10k-name list is not main-thread work; these
    // run on the global executor (see HTTPClient.decode for why that has
    // to be explicit).
    @concurrent
    private static func read<T: Codable & Sendable>(_ url: URL) async -> Entry<T>? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry<T>.self, from: data)
    }

    @concurrent
    private static func write<T: Codable & Sendable>(_ entry: Entry<T>, to url: URL) async {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
