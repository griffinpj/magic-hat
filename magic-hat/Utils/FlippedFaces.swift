//
//  FlippedFaces.swift
//  magic-hat
//
//  Which double-faced printings the user has turned over: a card flipped
//  in the viewer stays flipped — the tile, the viewer and the fan show its
//  back until it is flipped again. Keyed by Scryfall id (the printing),
//  kept in UserDefaults as a plain array: it holds only what was flipped
//  by hand, a few dozen ids at most, and is read on every store pass over
//  the rows, so it lives in memory behind a lock rather than being decoded
//  per card. Travels with backups through `BackupController.settingsKeys`.
//

import Foundation
import os

nonisolated enum FlippedFaces {
    static let key = "cards.flipped"

    private static let cache = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    private static func current() -> Set<String> {
        cache.withLock { state in
            if let state { return state }
            let stored = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            state = stored
            return stored
        }
    }

    static func contains(_ scryfallID: String) -> Bool {
        current().contains(scryfallID)
    }

    /// Flips the printing's remembered face; returns the new state.
    @discardableResult
    static func toggle(_ scryfallID: String) -> Bool {
        cache.withLock { state -> Bool in
            var set = state ?? Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            let showsBack: Bool
            if set.contains(scryfallID) { set.remove(scryfallID); showsBack = false } else { set.insert(scryfallID); showsBack = true }
            state = set
            UserDefaults.standard.set(Array(set).sorted(), forKey: key)
            return showsBack
        }
    }

    /// Remembers the face for the printing.
    static func set(_ scryfallID: String, showsBack: Bool) {
        cache.withLock { state in
            var set = state ?? Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            if showsBack { set.insert(scryfallID) } else { set.remove(scryfallID) }
            state = set
            UserDefaults.standard.set(Array(set).sorted(), forKey: key)
        }
    }

    /// After a restore wrote the key behind the cache.
    static func reload() {
        cache.withLock { $0 = nil }
    }
}
