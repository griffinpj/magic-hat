//
//  MTGCollection.swift
//  magic-hat
//
//  A named top-level collection that owns binders (which own cards). Import
//  targets a single collection: an existing one to merge into, or a new one.
//  Named MTGCollection to avoid clashing with Swift's `Collection`.
//

import Foundation
import SwiftData

@Model
final class MTGCollection {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    var createdDate: Date

    init(id: UUID = UUID(), name: String, createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
    }
}
