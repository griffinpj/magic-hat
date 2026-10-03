import Testing
import Foundation
@testable import magic_hat

/// The import's dry run: new rows against merges by the import's own key,
/// duplicates within the file counted once, Replace's removals.
@Suite("ImportPreview")
struct ImportPreviewTests {
    @Test func countsNewAndMergingRowsByMergeKey() {
        let rows = [
            TestSupport.row(binder: "A", id: "x", quantity: 2),
            TestSupport.row(binder: "A", id: "x", quantity: 1),             // same printing twice in the file
            TestSupport.row(binder: "A", id: "y", finish: "foil", quantity: 1),
            TestSupport.row(binder: "B", id: "z", quantity: 4),             // not selected
        ]
        let xKey = CollectionEntry.mergeKey(scryfallID: "x", collectionName: "Main", finish: "normal", condition: "near_mint")
        let preview = ImportPreview.compute(rows: rows, selectedBinders: ["A"], collectionName: "Main", mode: .add,
                                            existing: [xKey: 5, "other": 1])
        #expect(preview.fileRows == 3 && preview.copies == 4)
        #expect(preview.newRows == 1, "the foil y")
        #expect(preview.mergingRows == 1 && preview.mergedCopies == 3, "both x rows land on the existing x")
        #expect(preview.removedRows == 0 && preview.removedCopies == 0)
        #expect(preview.lines == ["Adds 4 copies from 3 rows.", "1 new row; 3 copies merge into 1 row you already have."])
    }

    @Test func replaceRemovesEverythingFirstAndMergesNothing() {
        let rows = [TestSupport.row(binder: "A", id: "x", quantity: 2)]
        let xKey = CollectionEntry.mergeKey(scryfallID: "x", collectionName: "Main", finish: "normal", condition: "near_mint")
        let preview = ImportPreview.compute(rows: rows, selectedBinders: ["A"], collectionName: "Main", mode: .replace,
                                            existing: [xKey: 5, "other": 3])
        #expect(preview.removedRows == 2 && preview.removedCopies == 8)
        #expect(preview.newRows == 1 && preview.mergingRows == 0)
        #expect(preview.lines.first == "Removes 8 copies (2 rows) first.")
    }

    @Test func nothingSelectedIsEmpty() {
        let preview = ImportPreview.compute(rows: [TestSupport.row(binder: "A", id: "x", quantity: 1)], selectedBinders: [],
                                            collectionName: "Main", mode: .add, existing: [:])
        #expect(preview.isEmpty && preview.lines == ["Nothing selected."])
    }
}

extension ImportPreviewTests {
    /// The file the UI tour writes, through the real parser: a new
    /// collection merges nothing.
    @Test func parsedFileIntoANewCollection() throws {
        let header = "Binder Name,Binder Type,Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,Purchase price,Misprint,Altered,Condition,Language,Purchase price currency,Added"
        func row(_ binder: String, _ i: Int, qty: Int, id: String? = nil) -> String {
            let sid = id ?? String(format: "00000000-0000-4000-8000-%012d", i)
            return "\(binder),binder,Card \(i),one,Set 0,\(i),normal,common,\(qty),1,\(sid),0.5,false,false,near_mint,en,USD,2024-04-14T23:32:26.393Z"
        }
        let text = ([header, row("Binder A", 0, qty: 2), row("Binder A", 0, qty: 1), row("Binder A", 4, qty: 3),
                     row("Binder B", 999_999, qty: 4, id: "11111111-1111-4111-8111-111111111111")] + [""]).joined(separator: "\r\n")
        let rows = try CSVParser.parseManaBox(text)
        #expect(rows.count == 4)
        let preview = ImportPreview.compute(rows: rows, selectedBinders: ["Binder A", "Binder B"], collectionName: "New Collection",
                                            mode: .add, existing: [:])
        #expect(preview.copies == 10 && preview.fileRows == 4)
        #expect(preview.newRows == 3 && preview.mergingRows == 0, "\(preview)")
    }
}
