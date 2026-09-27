//
//  DeckSiteClient.swift
//  magic-hat
//
//  A deck list from a link to a deck site, as the text DeckListParser
//  reads, so an import from a link goes through the same sheet, summary
//  and resolution as a pasted list:
//
//  - Archidekt: `archidekt.com/decks/<id>` → `GET /api/decks/<id>/`, JSON
//    with every card's category (Commander, Sideboard, Maybeboard …), its
//    printing, and the deck's name and format.
//  - Moxfield: `moxfield.com/decks/<id>` → `GET api2.moxfield.com/v3/decks/
//    all/<id>`. Moxfield puts its API behind a bot check and may refuse an
//    app; when it does the error says to use Moxfield's Export and paste.
//  - MTGGoldfish: `mtggoldfish.com/deck/<id>` → `/deck/download/<id>`, the
//    Arena-style text with the sideboard after a blank line.
//  - Anything else: the URL fetched as it is, taken if it is plain text
//    (a raw list, a pastebin's raw view, Deckstats' `?export_txt=1`).
//
//  Every source is shaped here; the parser never sees JSON.
//

import Foundation

nonisolated struct DeckSiteList: Sendable, Equatable {
    var name: String?
    var format: DeckFormat?
    /// In DeckListParser's shape: "// COMMANDER", "1 Name (SET) 123" …
    var text: String
}

nonisolated enum DeckSite: Equatable, Sendable {
    case archidekt(id: String)
    case moxfield(id: String)
    case mtggoldfish(id: String)
    case plain(URL)

    var label: String {
        switch self {
        case .archidekt: return "Archidekt"
        case .moxfield: return "Moxfield"
        case .mtggoldfish: return "MTGGoldfish"
        case .plain(let url): return url.host() ?? "the link"
        }
    }

    /// The site a pasted link points at; nil when it isn't a web link.
    static func recognise(_ raw: String) -> DeckSite? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        func after(_ marker: String) -> String? {
            guard let i = parts.firstIndex(where: { $0.lowercased() == marker }), i + 1 < parts.count else { return nil }
            return parts[i + 1]
        }
        if host.hasSuffix("archidekt.com"), let id = after("decks"), id.allSatisfy(\.isNumber) {
            return .archidekt(id: id)
        }
        if host.hasSuffix("moxfield.com"), let id = after("decks") {
            return .moxfield(id: id)
        }
        if host.hasSuffix("mtggoldfish.com"), let id = after("deck"), id != "download" {
            return .mtggoldfish(id: id.split(separator: "#").first.map(String.init) ?? id)
        }
        return .plain(url)
    }
}

nonisolated enum DeckSiteError: Error, LocalizedError, Equatable {
    case notALink
    case refused(site: String)
    case notFound
    case notAList

    var errorDescription: String? {
        switch self {
        case .notALink: return "That isn't a link to a deck."
        case .refused(let site): return "\(site) didn't let the app read this deck. On \(site), use Export → Copy, then paste the list here."
        case .notFound: return "The deck wasn't found. Is it public?"
        case .notAList: return "That page isn't a deck list the app can read. Copy the list from the site and paste it here."
        }
    }
}

nonisolated struct DeckSiteClient {
    static let shared = DeckSiteClient()
    private let http = HTTPClient(userAgent: "MagicHat/1.0", accept: "application/json, text/plain;q=0.9, */*;q=0.5")

    func fetch(_ link: String) async throws -> DeckSiteList {
        guard let site = DeckSite.recognise(link) else { throw DeckSiteError.notALink }
        do {
            switch site {
            case .archidekt(let id):
                let data = try await http.requestData(url: URL(string: "https://archidekt.com/api/decks/\(id)/")!, rateLimit: .deckSite)
                return try Self.archidekt(data)
            case .moxfield(let id):
                let data = try await http.requestData(url: URL(string: "https://api2.moxfield.com/v3/decks/all/\(id)")!, rateLimit: .deckSite)
                return try Self.moxfield(data)
            case .mtggoldfish(let id):
                let data = try await http.requestData(url: URL(string: "https://www.mtggoldfish.com/deck/download/\(id)")!, rateLimit: .deckSite)
                return try Self.plainText(data, splitSideboardAtBlankLine: true)
            case .plain(let url):
                let data = try await http.requestData(url: url, rateLimit: .deckSite)
                return try Self.plainText(data, splitSideboardAtBlankLine: false)
            }
        } catch HTTPError.badStatus(let code, _) where code == 404 {
            throw DeckSiteError.notFound
        } catch HTTPError.badStatus(let code, _) where code == 401 || code == 403 || code == 429 {
            throw DeckSiteError.refused(site: site.label)
        } catch HTTPError.decoding {
            throw DeckSiteError.notAList
        }
    }

    // MARK: Shapes (pure, tested against trimmed real responses)

    struct ArchidektDeck: Decodable {
        let name: String?
        let deckFormat: Int?
        let categories: [Category]?
        let cards: [Entry]

        struct Category: Decodable {
            let name: String
            let includedInDeck: Bool?
        }
        struct Entry: Decodable {
            let quantity: Int
            let categories: [String]?
            let modifier: String?
            let card: Card
        }
        struct Card: Decodable {
            let collectorNumber: String?
            let edition: Edition?
            let oracleCard: Oracle
        }
        struct Edition: Decodable { let editioncode: String? }
        struct Oracle: Decodable { let name: String }
    }

    static func archidekt(_ data: Data) throws -> DeckSiteList {
        let deck: ArchidektDeck
        do { deck = try JSONDecoder().decode(ArchidektDeck.self, from: data) } catch { throw DeckSiteError.notAList }
        // A category left out of the deck (Maybeboard, Considering …) is
        // the maybeboard; Sideboard is the sideboard; Commander the zone.
        let outOfDeck = Set((deck.categories ?? []).filter { $0.includedInDeck == false }.map { $0.name.lowercased() })
        var boards: [DeckBoard: [String]] = [:]
        for entry in deck.cards where entry.quantity > 0 {
            let categories = (entry.categories ?? []).map { $0.lowercased() }
            let board: DeckBoard
            if categories.contains("commander") { board = .commander }
            else if categories.contains("sideboard") { board = .side }
            else if categories.contains("maybeboard") || categories.contains(where: outOfDeck.contains) { board = .maybe }
            else { board = .main }
            boards[board, default: []].append(line(entry.quantity, entry.card.oracleCard.name, set: entry.card.edition?.editioncode,
                                                   number: entry.card.collectorNumber, foil: entry.modifier == "Foil"))
        }
        return DeckSiteList(name: deck.name, format: deck.deckFormat.flatMap(archidektFormat), text: text(boards))
    }

    /// Archidekt's numeric formats, the ones that map onto ours.
    static func archidektFormat(_ n: Int) -> DeckFormat? {
        switch n {
        case 1: return .standard
        case 2: return .modern
        case 3: return .commander
        case 4: return .legacy
        case 5: return .vintage
        case 6: return .pauper
        case 13: return .brawl
        case 14: return .oathbreaker
        case 15: return .pioneer
        default: return nil
        }
    }

    struct MoxfieldDeck: Decodable {
        let name: String?
        let format: String?
        let boards: [String: Board]

        struct Board: Decodable {
            let cards: [String: Entry]?
        }
        struct Entry: Decodable {
            let quantity: Int
            let isFoil: Bool?
            let card: Card
        }
        struct Card: Decodable {
            let name: String
            let set: String?
            let cn: String?
        }
    }

    static func moxfield(_ data: Data) throws -> DeckSiteList {
        let deck: MoxfieldDeck
        do { deck = try JSONDecoder().decode(MoxfieldDeck.self, from: data) } catch { throw DeckSiteError.notAList }
        var boards: [DeckBoard: [String]] = [:]
        for (key, board) in deck.boards {
            let target: DeckBoard?
            switch key.lowercased() {
            case "commanders": target = .commander
            case "mainboard": target = .main
            case "sideboard", "companions": target = .side
            case "maybeboard": target = .maybe
            default: target = nil   // tokens, attractions, stickers
            }
            guard let target else { continue }
            let entries = (board.cards ?? [:]).values.sorted { $0.card.name < $1.card.name }
            for entry in entries where entry.quantity > 0 {
                boards[target, default: []].append(line(entry.quantity, entry.card.name, set: entry.card.set,
                                                        number: entry.card.cn, foil: entry.isFoil == true))
            }
        }
        return DeckSiteList(name: deck.name, format: deck.format.flatMap { DeckFormat(rawValue: $0.lowercased()) }, text: text(boards))
    }

    /// A text list as served. MTGGoldfish's has no headers: the sideboard
    /// follows the first blank line.
    static func plainText(_ data: Data, splitSideboardAtBlankLine: Bool) throws -> DeckSiteList {
        guard let raw = String(data: data, encoding: .utf8), !raw.contains("<html"), !raw.contains("<!DOCTYPE") else {
            throw DeckSiteError.notAList
        }
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if splitSideboardAtBlankLine, let range = text.range(of: "\n\n") {
            let rest = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[..<range.lowerBound]) + (rest.isEmpty ? "" : "\n\n// SIDEBOARD\n" + rest)
        }
        guard !DeckListParser.parse(text).isEmpty else { throw DeckSiteError.notAList }
        return DeckSiteList(name: nil, format: nil, text: text)
    }

    private static func line(_ quantity: Int, _ name: String, set: String?, number: String?, foil: Bool) -> String {
        var s = "\(quantity) \(name)"
        if let set, !set.isEmpty, let number, !number.isEmpty { s += " (\(set.uppercased())) \(number)" }
        if foil { s += " *F*" }
        return s
    }

    private static func text(_ boards: [DeckBoard: [String]]) -> String {
        var out: [String] = []
        for (board, header) in [(DeckBoard.commander, "// COMMANDER"), (.main, "// MAINBOARD"), (.side, "// SIDEBOARD"), (.maybe, "// MAYBEBOARD")] {
            guard let lines = boards[board], !lines.isEmpty else { continue }
            if !out.isEmpty { out.append("") }
            out.append(header)
            out.append(contentsOf: lines)
        }
        return out.joined(separator: "\n")
    }
}
