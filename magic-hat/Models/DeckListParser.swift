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
            // Any other "//" or "#" line is a comment — a type grouping
            // ("// Creatures (12)") or a note — not a card named "// …".
            if line.hasPrefix("//") || line.hasPrefix("#") { continue }
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

    /// The text form the app exports (and re-imports), with the defaults.
    static func export(_ snapshot: DeckSnapshot) -> String {
        export(snapshot, options: DeckExportOptions())
    }

    /// The list as text, shaped by the options: the header style, which
    /// boards, grouped by type or not, sorted, with or without printings,
    /// every card or only what the collection can't supply.
    static func export(_ snapshot: DeckSnapshot, options: DeckExportOptions) -> String {
        var out: [String] = []

        func line(_ item: DeckCardItem, quantity: Int) -> String {
            let card = item.card
            let printing = options.includesPrintings && !card.setCode.isEmpty
                ? " (\(card.setCode.uppercased())) \(card.collectorNumber)" : ""
            return "\(quantity) \(card.name)\(printing)"
        }

        func quantity(_ item: DeckCardItem) -> Int {
            options.onlyMissing ? item.missingQuantity : item.quantity
        }

        func sorted(_ items: [DeckCardItem]) -> [DeckCardItem] {
            items.sorted { a, b in
                switch options.ordering {
                case .name:
                    break
                case .price:
                    let pa = a.card.priceUSD ?? 0, pb = b.card.priceUSD ?? 0
                    if pa != pb { return pa > pb }
                case .manaValue:
                    let ma = ManaSymbol.manaValue(of: a.card.manaCost ?? ""), mb = ManaSymbol.manaValue(of: b.card.manaCost ?? "")
                    if ma != mb { return ma < mb }
                }
                if a.card.sortKey != b.card.sortKey { return a.card.sortKey < b.card.sortKey }
                return a.card.id < b.card.id
            }
        }

        /// One board: header, then its rows — in type groups with a comment
        /// line each, or flat.
        func board(_ header: String, _ items: [DeckCardItem], grouped: [DeckSection]? = nil) {
            let kept = items.filter { quantity($0) > 0 }
            guard !kept.isEmpty else { return }
            if !out.isEmpty { out.append("") }
            out.append(header)
            if let grouped, options.grouping == .type, options.format == .standard {
                var first = true
                for section in grouped {
                    let rows = sorted(section.items.filter { quantity($0) > 0 })
                    guard !rows.isEmpty else { continue }
                    if !first { out.append("") }
                    first = false
                    out.append("// \(section.title) (\(rows.reduce(0) { $0 + quantity($1) }))")
                    for item in rows { out.append(line(item, quantity: quantity(item))) }
                }
            } else {
                for item in sorted(kept) { out.append(line(item, quantity: quantity(item))) }
            }
        }

        let arena = options.format == .arena
        if options.boards.contains(.main) {
            board(arena ? "Commander" : "// COMMANDER", snapshot.commanders)
            board(arena ? "Deck" : "// MAINBOARD", snapshot.sections.flatMap(\.items), grouped: snapshot.sections)
        }
        if options.boards.contains(.side) {
            board(arena ? "Sideboard" : "// SIDEBOARD", snapshot.sideboard)
        }
        if options.boards.contains(.maybe), !arena {
            board("// MAYBEBOARD", snapshot.maybeboard)
        }
        return out.joined(separator: "\n")
    }
}

/// How a deck list is written out. `standard` is the "// HEADER" shape every
/// deck site reads and this app re-imports; `arena` is what MTG Arena's
/// importer expects (Commander / Deck / Sideboard, nothing else — so no
/// type groups and no maybeboard in that format).
nonisolated struct DeckExportOptions: Hashable, Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case standard, arena
        var id: String { rawValue }
        var label: String { self == .standard ? "Default" : "Arena" }
    }
    enum Grouping: String, CaseIterable, Identifiable, Sendable {
        case board, type
        var id: String { rawValue }
        var label: String { self == .board ? "Board" : "Card type" }
    }
    enum Ordering: String, CaseIterable, Identifiable, Sendable {
        case name, price, manaValue
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: return "Name"
            case .price: return "Price"
            case .manaValue: return "Mana value"
            }
        }
    }

    var format: Format = .standard
    var grouping: Grouping = .board
    var ordering: Ordering = .name
    /// "(SET) 123" after each name.
    var includesPrintings = true
    /// Only the copies the collection can't supply — a shopping list.
    var onlyMissing = false
    /// The commander goes with the mainboard.
    var boards: Set<DeckBoard> = [.main, .side]
}
