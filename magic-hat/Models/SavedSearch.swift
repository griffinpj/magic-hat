//
//  SavedSearch.swift
//  magic-hat
//
//  A named CardSearchQuery the user wants back. Lives in SwiftData next to
//  the collections rather than in UserDefaults: it is a real, unbounded,
//  user-managed list (rename, delete, reorder), it should survive with the
//  rest of the user's data, and one store means one place to back up or
//  later sync. The query is stored as JSON so the filter model can grow
//  without a schema migration — unknown fields decode to their defaults.
//

import Foundation
import SwiftData

@Model
nonisolated final class SavedSearch {
    @Attribute(.unique) var id: UUID
    var name: String
    var queryData: Data
    var createdDate: Date
    var lastUsedDate: Date
    /// Manual order in the list; lower first.
    var sortOrder: Int

    init(id: UUID = UUID(), name: String, query: CardSearchQuery, sortOrder: Int = 0,
         createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.queryData = (try? JSONEncoder().encode(query)) ?? Data()
        self.createdDate = createdDate
        self.lastUsedDate = createdDate
        self.sortOrder = sortOrder
    }

    var query: CardSearchQuery {
        get { (try? JSONDecoder().decode(CardSearchQuery.self, from: queryData)) ?? CardSearchQuery() }
        set { queryData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}
