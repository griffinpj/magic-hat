//
//  DiskJSONCache.swift
//  magic-hat
//
//  A small Codable cache — memory, then a JSON file per key under
//  Caches/ — for the answers the deck analysis and the synergy screen
//  fetch from outside (Commander Spellbook, Recommander, EDHREC, Scryfall's
//  oracle-tag lists). Each answer is the same for the same question until
//  the world changes, so every one is kept with the time it was fetched
//  and read back within a TTL the caller chooses; a stale answer can be
//  read too, to show while a refresh runs. An actor: decoding and writing
//  happen on its executor, never the main thread.
//

import Foundation
import CryptoKit

actor DiskJSONCache {
    nonisolated private struct Envelope<T: Codable>: Codable {
        let value: T
        let fetchedAt: Date
    }

    private struct Slot {
        let fetchedAt: Date
        let value: any Sendable
    }

    private let directory: URL
    private var memory: [String: Slot] = [:]

    init(folder: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The value for `key` if it was fetched within `ttl`.
    func value<T: Codable & Sendable>(_ type: T.Type, key: String, ttl: TimeInterval) -> T? {
        guard let (value, fetchedAt) = stale(type, key: key) else { return nil }
        return Date().timeIntervalSince(fetchedAt) < ttl ? value : nil
    }

    /// The value for `key` however old, with when it was fetched.
    func stale<T: Codable & Sendable>(_ type: T.Type, key: String) -> (value: T, fetchedAt: Date)? {
        if let slot = memory[key], let value = slot.value as? T { return (value, slot.fetchedAt) }
        guard let data = try? Data(contentsOf: fileURL(key)),
              let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else { return nil }
        memory[key] = Slot(fetchedAt: envelope.fetchedAt, value: envelope.value)
        return (envelope.value, envelope.fetchedAt)
    }

    func fetchedAt(key: String) -> Date? {
        if let slot = memory[key] { return slot.fetchedAt }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(key).path)
        return attrs?[.modificationDate] as? Date
    }

    func store<T: Codable & Sendable>(_ value: T, key: String) {
        let now = Date()
        memory[key] = Slot(fetchedAt: now, value: value)
        guard let data = try? JSONEncoder().encode(Envelope(value: value, fetchedAt: now)) else { return }
        try? data.write(to: fileURL(key), options: .atomic)
    }

    func remove(key: String) {
        memory[key] = nil
        try? FileManager.default.removeItem(at: fileURL(key))
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(Self.safeName(key)).appendingPathExtension("json")
    }

    /// Keys are hashes, oracle ids and slugs already; anything else is hashed.
    nonisolated static func safeName(_ key: String) -> String {
        let safe = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return safe && key.count <= 120 ? key : hash(key)
    }

    /// SHA-256 hex of a string: the key for a whole deck list, a card name.
    nonisolated static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
