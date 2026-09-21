import Testing
import Foundation
@testable import magic_hat

@Suite("CSVParser")
struct CSVParserTests {
    /// The bug that shipped: "\r\n" is one Swift Character, so a parser that
    /// walks Characters never sees "\n" and collapses the file into one row.
    @Test func crlfLinesAreSeparateRows() {
        let rows = CSVParser.parse("a,b\r\n1,2\r\n3,4\r\n")
        #expect(rows.count == 3)
        #expect(rows[1] == ["1", "2"])
        #expect(rows[2] == ["3", "4"])
    }

    @Test func quotedFieldsKeepCommasAndEscapedQuotes() {
        let rows = CSVParser.parse("name,note\n\"Jace, the Mind Sculptor\",\"says \"\"hi\"\"\"\n")
        #expect(rows[1] == ["Jace, the Mind Sculptor", "says \"hi\""])
    }

    @Test func trailingLineWithoutNewlineIsKept() {
        let rows = CSVParser.parse("a\n1\n2")
        #expect(rows.count == 3)
    }

    @Test func manaBoxRowsMapByHeaderName() throws {
        let header = ManaBoxRow.expectedHeader.joined(separator: ",")
        let line = "Library,binder,Wastes,OGW,Oath of the Gatewatch,184,foil,common,2,9197,69b215fe-0d97-4ca1-9490-174220fd454b,0.86,false,false,near_mint,en,USD,2024-04-14T23:32:26.393Z"
        let rows = try CSVParser.parseManaBox("\(header)\r\n\(line)\r\n")
        #expect(rows.count == 1)
        let r = try #require(rows.first)
        #expect(r.binderName == "Library")
        #expect(r.quantity == 2)
        #expect(r.finish == .foil)
        #expect(r.scryfallID == "69b215fe-0d97-4ca1-9490-174220fd454b")
        #expect(r.purchasePrice == 0.86)
        #expect(r.added != nil)
    }

    @Test func manaBoxRejectsUnexpectedHeader() {
        #expect(throws: ManaBoxParseError.self) {
            _ = try CSVParser.parseManaBox("foo,bar\n1,2\n")
        }
    }

    @Test func duplicateHeaderColumnsDoNotCrash() throws {
        // Two "Name" columns: must error or take the first, never trap.
        let text = "Name,Name,Scryfall ID,Quantity,Binder Name\nA,B,id-1,1,X\n"
        let rows = try CSVParser.parseManaBox(text)
        #expect(rows.first?.name == "A")
    }
}
