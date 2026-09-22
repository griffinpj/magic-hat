//
//  DeckChangeTracker.swift
//  magic-hat
//
//  Same idea as CollectionChangeTracker, for deck lists: every deck write
//  bumps it once; deck views key a `.task(id:)` on it. Builds bump both
//  trackers, because they move collection rows too.
//

import Foundation

@MainActor
@Observable
final class DeckChangeTracker {
    static let shared = DeckChangeTracker()
    private(set) var revision = 0
    func bump() { revision &+= 1 }
}
