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
