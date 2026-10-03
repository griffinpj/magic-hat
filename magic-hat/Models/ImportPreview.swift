//
//  ImportPreview.swift
//  magic-hat
//
//  What an import will do before it does it: the rows it takes, how many
//  land as new rows and how many merge into rows the collection already
//  has (by `mergeKey`, the same rule the import applies), and what Replace
//  throws away first. Pure, over counts the store reads once per change
//  of the wizard's choices, so the confirm step can say "adds 3,846 rows,
//  1,200 merge into ones you have" rather than "n rows".
//

import Foundation

nonisolated struct ImportPreview: Hashable, Sendable {
    /// Rows taken from the file (the selected binders), before merging.
    let fileRows: Int
    /// Copies those rows add.
    let copies: Int
    /// Rows the collection will gain.
    let newRows: Int
    /// Rows that merge into a row already in the collection (add mode).
    let mergingRows: Int
    /// Copies that land on existing rows.
    let mergedCopies: Int
    /// Replace mode: rows and copies removed first.
    let removedRows: Int
    let removedCopies: Int

    var isEmpty: Bool { fileRows == 0 }

    /// `existing` is the destination's rows as merge key → copies; empty
    /// for a new collection. Duplicate printings within the file merge
    /// with each other, as they do on import.
    static func compute(rows: [ManaBoxRow], selectedBinders: Set<String>, collectionName: String,
                        mode: ImportMode, existing: [String: Int]) -> ImportPreview {
        let taken = rows.filter { selectedBinders.contains($0.binderName) }
        var keys: [String: Int] = [:]
        var copies = 0
        for row in taken {
            let key = CollectionEntry.mergeKey(scryfallID: row.scryfallID, collectionName: collectionName,
                                               finish: row.finish.rawValue, condition: row.condition)
            keys[key, default: 0] += row.quantity
            copies += row.quantity
        }
        let kept = mode == .add ? existing : [:]
        var merging = 0, merged = 0
        for (key, qty) in keys where kept[key] != nil {
            merging += 1
            merged += qty
        }
        return ImportPreview(
            fileRows: taken.count, copies: copies,
            newRows: keys.count - merging, mergingRows: merging, mergedCopies: merged,
            removedRows: mode == .replace ? existing.count : 0,
            removedCopies: mode == .replace ? existing.values.reduce(0, +) : 0
        )
    }

    /// The lines the wizard shows, in order.
    var lines: [String] {
        guard !isEmpty else { return ["Nothing selected."] }
        func n(_ count: Int, _ word: String) -> String { "\(count.formatted()) \(word)\(count == 1 ? "" : "s")" }
        func copies(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "copy" : "copies")" }
        var out: [String] = []
        if removedRows > 0 {
            out.append("Removes \(copies(removedCopies)) (\(n(removedRows, "row"))) first.")
        }
        out.append("Adds \(copies(self.copies)) from \(n(fileRows, "row")).")
        if mergingRows > 0 {
            out.append("\(n(newRows, "new row")); \(copies(mergedCopies)) merge into \(n(mergingRows, "row")) you already have.")
        } else {
            out.append("\(n(newRows, "new row")).")
        }
        return out
    }
}
