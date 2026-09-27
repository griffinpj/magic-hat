//
//  DeckFolder.swift
//  magic-hat
//
//  A folder on the Decks tab, the Files app's idea: folders hold decks and
//  other folders, as deep as the user likes. A deck names its folder
//  (`Deck.folderID`, nil at the top level) and a folder its parent, so
//  moving either is one field. Deleting a folder never deletes a deck: its
//  contents move up to its parent.
//

import Foundation
import SwiftData

@Model
nonisolated final class DeckFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    /// The folder this one is in; nil at the top level.
    var parentID: UUID?
    var createdDate: Date

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil, createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdDate = createdDate
    }
}

/// The folder tree as plain values, for the pickers and the path above a
/// folder. Built from the (small) table in memory.
nonisolated struct DeckFolderTree: Sendable {
    struct Node: Identifiable, Hashable, Sendable {
        let id: UUID
        let name: String
        let parentID: UUID?
    }

    let nodes: [UUID: Node]

    init(_ folders: [DeckFolder]) {
        nodes = Dictionary(folders.map { ($0.id, Node(id: $0.id, name: $0.name, parentID: $0.parentID)) },
                           uniquingKeysWith: { a, _ in a })
    }

    init(nodes: [Node]) {
        self.nodes = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Folders directly in `parent` (nil: the top level), by name.
    func children(of parent: UUID?) -> [Node] {
        nodes.values.filter { $0.parentID == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// From the top level down to `id`, inclusive.
    func path(to id: UUID?) -> [Node] {
        var out: [Node] = []
        var cursor = id
        var seen = Set<UUID>()
        while let c = cursor, let node = nodes[c], seen.insert(c).inserted {
            out.insert(node, at: 0)
            cursor = node.parentID
        }
        return out
    }

    /// Whether `id` is `ancestor` or somewhere inside it — a folder can't
    /// move into itself or its own subfolders.
    func isInside(_ id: UUID?, _ ancestor: UUID) -> Bool {
        path(to: id).contains { $0.id == ancestor }
    }

    /// Every folder depth-first under `parent`, with its depth, for a
    /// Files-style destination list.
    func flattened(under parent: UUID? = nil, depth: Int = 0) -> [(node: Node, depth: Int)] {
        children(of: parent).flatMap { [($0, depth)] + flattened(under: $0.id, depth: depth + 1) }
    }
}
