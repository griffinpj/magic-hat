//
//  CollectionChangeTracker.swift
//  magic-hat
//
//  Views no longer hold @Query over large tables; they ask CollectionStore
//  for value snapshots instead. This is how they know to ask again: every
//  write path (import, delete, later deck moves) bumps `revision` once when
//  it finishes, and views key a `.task(id:)` on it.
//

import Foundation

@MainActor
@Observable
final class CollectionChangeTracker {
    static let shared = CollectionChangeTracker()
    private(set) var revision = 0
    func bump() { revision &+= 1 }
}

/// A card's remembered face changed (`FlippedFaces`). Its own revision:
/// a flip used to bump `CollectionChangeTracker`, which refetched every
/// row, the overview, History and Search for one printing's face. The
/// store carries it in `StoreStamp` and rewrites `showsBack` over its
/// cached rows; the grid, the deck screen and Search key on it too.
@MainActor
@Observable
final class FlipTracker {
    static let shared = FlipTracker()
    private(set) var revision = 0
    func bump() { revision &+= 1 }
}
