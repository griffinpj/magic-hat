//
//  DeckListParser.swift
//  magic-hat
//
//  Reads the deck-list text every deck site exports — Moxfield, Archidekt,
//  MTGO, Arena, TappedOut — into lines with a quantity, a name, an optional
//  printing (set code + collector number), a foil flag and a board.
//
//    // COMMANDER            ← section headers, with or without // or :
//    1 Dáin of the Ancient Halls (HOC) 104
//    15 Mountain (SOS) 278
//    1 Mithril Coat (LTR) 245 *F*
//    // SIDEBOARD
//
//  Pure and nonisolated; the fixture "King under the Mountain" is the
//  contract.
//

import Foundation

nonisolated struct DeckListLine: Hashable, Sendable {
    var quantity: Int
    var name: String
    var setCode: String?
    var collectorNumber: String?
    var isFoil: Bool
    var board: DeckBoard
    var raw: String
}

nonisolated struct DeckList: Hashable, Sendable {
    var lines: [DeckListLine] = []
    /// "Name …" from an Arena export's About block, if present.
    var title: String?
    /// Lines that looked like cards but couldn't be read.
    var unparsed: [String] = []

    func lines(in board: DeckBoard) -> [DeckListLine] { lines.filter { $0.board == board } }
    func copies(in board: DeckBoard) -> Int { lines(in: board).reduce(0) { $0 + $1.quantity } }
    var hasCommander: Bool { lines.contains { $0.board == .commander } }
    var totalCopies: Int { lines.reduce(0) { $0 + $1.quantity } }
    var isEmpty: Bool { lines.isEmpty }

    /// Commander if the list has one, else casual: the list can't tell a
    /// 60-card format apart, and the user picks in the import sheet anyway.
    var suggestedFormat: DeckFormat { hasCommander ? .commander : .other }
}

nonisolated enum DeckListParser {
    static func parse(_ text: String) -> DeckList {
        var list = DeckList()
        var board: DeckBoard = .main
        var pendingTitle = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // Moxfield gives the mainboard no header: the blank line
                // after the one- or two-card commander section is it.
                if board == .commander { board = .main }
                continue
            }

            if let header = sectionHeader(line) {
                board = header
                continue
            }
            let lower = line.lowercased()
            if lower == "about" { pendingTitle = true; continue }
            if pendingTitle, lower.hasPrefix("name ") {
                list.title = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                pendingTitle = false
                continue
            }
            pendingTitle = false

            if let parsed = cardLine(line, board: board) {
                list.lines.append(parsed)
            } else {
                list.unparsed.append(line)
            }
        }
        return list
    }

    /// "// COMMANDER", "Sideboard:", "Deck", "MAYBEBOARD" …
    private static func sectionHeader(_ line: String) -> DeckBoard? {
        var s = line
        while s.hasPrefix("/") || s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix(":") { s.removeLast() }
        // "Sideboard (2)" style counts.
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        let key = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "commander", "commanders", "command zone", "commander zone": return .commander
        case "deck", "main", "mainboard", "main deck", "maindeck", "main board", "library": return .main
        case "sideboard", "side", "side board", "companion": return .side
        case "maybeboard", "maybe", "maybe board", "considering", "wishlist", "tokens": return .maybe
        default: return nil
        }
    }

    // "1 Name (SET) 123 *F*", "4x Name", "Name"
    private static let pattern = try! NSRegularExpression(pattern:
        #"^(?:(\d+)\s*[xX]?\s+)?(.+?)(?:\s+\(([A-Za-z0-9]{2,6})\)(?:\s+([A-Za-z0-9★†\-]+))?)?(?:\s+\*F\*|\s+\[foil\]|\s+\(foil\)|\s+\*E\*)?(?:\s+#\S.*)?\s*$"#
    )

    static func cardLine(_ line: String, board: DeckBoard) -> DeckListLine? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = pattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: line) else { return nil }
            return String(line[swiftRange])
        }
        guard let name = group(2)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        // A bare number, or something that reads as a header we didn't know.
        guard name.rangeOfCharacter(from: .letters) != nil else { return nil }
        let quantity = group(1).flatMap(Int.init) ?? 1
        guard quantity > 0 else { return nil }
        let lower = line.lowercased()
        let foil = lower.contains("*f*") || lower.contains("[foil]") || lower.contains("(foil)") || lower.contains("*e*")
        return DeckListLine(
            quantity: quantity,
            name: name,
            setCode: group(3)?.lowercased(),
            collectorNumber: group(4),
            isFoil: foil,
            board: board,
            raw: line
        )
    }

    /// The text form the app exports (and re-imports).
    static func export(_ snapshot: DeckSnapshot) -> String {
        var out: [String] = []
        func section(_ title: String, _ items: [DeckCardItem]) {
            guard !items.isEmpty else { return }
            if !out.isEmpty { out.append("") }
            out.append("// \(title)")
            for item in items {
                let printing = item.card.setCode.isEmpty ? "" : " (\(item.card.setCode.uppercased())) \(item.card.collectorNumber)"
                out.append("\(item.quantity) \(item.card.name)\(printing)")
            }
        }
        section("COMMANDER", snapshot.commanders)
        section("MAINBOARD", snapshot.sections.flatMap(\.items))
        section("SIDEBOARD", snapshot.sideboard)
        section("MAYBEBOARD", snapshot.maybeboard)
        return out.joined(separator: "\n")
    }
}
