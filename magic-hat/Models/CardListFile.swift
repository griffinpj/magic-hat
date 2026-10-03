//
//  CardListFile.swift
//  magic-hat
//
//  Reads a file or pasted text of cards, whatever made it, into rows a
//  collection or list can take: a quantity, a name, and whatever else the
//  source knew — the printing (Scryfall id, or set and number), finish,
//  condition, language, the price paid.
//
//  Three shapes, told apart by the text itself, never by the file's name:
//
//  - a table (CSV, semicolons or tabs; quoted fields; a BOM; Excel's
//    "sep=," line) with a header row. Columns are found by what they are
//    called, across the apps that export one — ManaBox, Moxfield,
//    Archidekt, Deckbox, Dragon Shield, TCGplayer, Delver Lens, Deckstats,
//    MTGGoldfish, CardSphere, Card Kingdom, a spreadsheet of one's own —
//    so the order and the extras don't matter. With no header, two columns
//    of a count and a name are read as that.
//  - MTGO's .dek (XML: <Cards Quantity="4" Name="…" Sideboard="true"/>).
//  - a list in text, one card a line, in any shape DeckListParser reads.
//
//  Pure and nonisolated: parsed off the main actor, tested on the sample
//  files in the test bundle (`import-*.csv|txt|dek`), which are the
//  contract for what is supported.
//

import Foundation

/// One row of an imported list.
nonisolated struct ImportedCard: Hashable, Sendable {
    var quantity: Int
    var name: String
    var setCode: String?
    /// The set by name, when the source gives no code ("Magic 2011").
    var setName: String?
    var collectorNumber: String?
    var scryfallID: String?
    var finish: CardFinish = .normal
    /// A `CardCondition` raw value.
    var condition: String = CardCondition.nearMint.rawValue
    /// Scryfall's language code; nil when the source doesn't say.
    var language: String?
    var purchasePrice: Double?
    /// ISO code of the price's currency, when the source says.
    var purchaseCurrency: String?
}

nonisolated struct CardListFile: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A table; `source` is the app it looks like, for the summary.
        case table(source: String)
        case mtgoDek
        case text
    }

    var kind: Kind = .text
    var cards: [ImportedCard] = []
    /// Lines or rows that looked like cards but couldn't be read.
    var unparsed: [String] = []

    var isEmpty: Bool { cards.isEmpty }
    var totalCopies: Int { cards.reduce(0) { $0 + $1.quantity } }
    var foilCopies: Int { cards.filter { $0.finish != .normal }.reduce(0) { $0 + $1.quantity } }
    /// Rows that name their printing (an id, or a set and number).
    var exactPrintings: Int {
        cards.filter { $0.scryfallID != nil || ($0.setCode != nil && $0.collectorNumber != nil) }.count
    }

    /// "Moxfield CSV", "MTGO deck file", "Text list".
    var label: String {
        switch kind {
        case .table(let source): return source
        case .mtgoDek: return "MTGO deck file"
        case .text: return "Text list"
        }
    }

    /// A ManaBox export with every column the ManaBox importer wants: the
    /// import sheet hands those to it, since it also keeps ManaBox's own
    /// ids and added dates.
    var isManaBox: Bool { kind == .table(source: "ManaBox CSV") }
}

nonisolated enum CardListReader {
    static func read(_ raw: String) -> CardListFile {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CardListFile() }

        if trimmed.hasPrefix("<"), trimmed.range(of: "<Cards ", options: .caseInsensitive) != nil {
            return readDek(trimmed)
        }
        if let table = readTable(text) { return table }
        return readText(text)
    }

    // MARK: Text

    private static func readText(_ text: String) -> CardListFile {
        let list = DeckListParser.parse(text)
        var file = CardListFile(kind: .text)
        file.unparsed = list.unparsed
        file.cards = list.lines.map { line in
            ImportedCard(quantity: line.quantity, name: line.name, setCode: line.setCode,
                         collectorNumber: line.collectorNumber,
                         finish: line.isEtched ? .etched : (line.isFoil ? .foil : .normal))
        }
        return file
    }

    // MARK: MTGO .dek

    private static let dekCard = try! NSRegularExpression(pattern: #"<Cards\b([^>]*)/?>"#, options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*"([^"]*)""#)

    private static func readDek(_ text: String) -> CardListFile {
        var file = CardListFile(kind: .mtgoDek)
        let range = NSRange(text.startIndex..., in: text)
        for match in dekCard.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let body = String(text[r])
            var attributes: [String: String] = [:]
            for a in attribute.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let k = Range(a.range(at: 1), in: body), let v = Range(a.range(at: 2), in: body) else { continue }
                attributes[body[k].lowercased()] = unescapeXML(String(body[v]))
            }
            guard let name = attributes["name"], !name.isEmpty else { file.unparsed.append(body); continue }
            let quantity = Int(attributes["quantity"] ?? "") ?? 1
            guard quantity > 0 else { continue }
            file.cards.append(ImportedCard(quantity: quantity, name: name))
        }
        return file
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Tables

    enum Column: Hashable, Sendable {
        case name, quantity, foilQuantity, setCode, setName, set, collectorNumber, finish, condition, language
        case scryfallID, price, currency
    }

    /// Header names, folded to letters and digits, by what they hold.
    /// "set" and "edition" alone are either a code or a name: the value
    /// decides, row by row.
    static let aliases: [String: Column] = [
        "name": .name, "cardname": .name, "card": .name, "title": .name, "cardtitle": .name,
        "quantity": .quantity, "qty": .quantity, "count": .quantity, "amount": .quantity, "quantityx": .quantity,
        "totalquantity": .quantity, "copies": .quantity, "owned": .quantity, "regqty": .quantity, "numberowned": .quantity,
        "foilqty": .foilQuantity, "foilquantity": .foilQuantity, "foilcount": .foilQuantity,
        "setcode": .setCode, "editioncode": .setCode, "setid": .setCode, "code": .setCode, "expansioncode": .setCode,
        "setabbreviation": .setCode, "setabbr": .setCode,
        "setname": .setName, "editionname": .setName, "expansion": .setName, "expansionname": .setName,
        "set": .set, "edition": .set,
        "collectornumber": .collectorNumber, "cardnumber": .collectorNumber, "collectorsnumber": .collectorNumber,
        "number": .collectorNumber, "cn": .collectorNumber, "collector": .collectorNumber, "num": .collectorNumber,
        "foil": .finish, "finish": .finish, "printing": .finish, "isfoil": .finish, "treatment": .finish,
        "condition": .condition, "cond": .condition, "grade": .condition,
        "language": .language, "lang": .language,
        "scryfallid": .scryfallID, "scryfalluuid": .scryfallID,
        "purchaseprice": .price, "pricebought": .price, "myprice": .price, "paid": .price, "pricepaid": .price,
        "cost": .price, "acquiredprice": .price, "buyprice": .price,
        "purchasepricecurrency": .currency, "currency": .currency,
    ]

    static func fold(_ header: String) -> String {
        String(String.UnicodeScalarView(header.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// The delimiter the first line uses most, outside quotes; nil when it
    /// uses none (a plain list).
    static func delimiter(of line: String) -> Unicode.Scalar? {
        var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for scalar in line.unicodeScalars {
            if scalar == "\"" { inQuotes.toggle() } else if !inQuotes, counts[scalar] != nil { counts[scalar]! += 1 }
        }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return best.key
    }

    /// The text as a table, or nil when it isn't one.
    private static func readTable(_ text: String) -> CardListFile? {
        var body = text
        // Excel's hint line.
        var hinted: Unicode.Scalar?
        if body.lowercased().hasPrefix("sep="), let newline = body.firstIndex(where: \.isNewline) {
            hinted = body.unicodeScalars.dropFirst(4).first
            body = String(body[body.index(after: newline)...])
        }
        let firstLine = String(body.prefix { !$0.isNewline })
        guard let delimiter = hinted ?? delimiter(of: firstLine) else { return nil }
        let rows = CSVParser.parse(body, delimiter: delimiter)
        guard let header = rows.first, header.count >= 2 else { return nil }

        var columns: [Column: Int] = [:]
        for (index, title) in header.enumerated() {
            if let column = aliases[fold(title)], columns[column] == nil { columns[column] = index }
        }
        // "Set ID" is the code in one export and a database number in
        // another (Deckstats), which then has "set_code" too: that wins.
        let folded = header.map(fold)
        if let explicit = folded.firstIndex(of: "setcode") ?? folded.firstIndex(of: "editioncode") { columns[.setCode] = explicit }
        if columns[.name] != nil {
            return table(rows: Array(rows.dropFirst()), columns: columns, source: source(of: header, columns: columns))
        }
        // No header: "4,Lightning Bolt" or "Lightning Bolt,4" throughout.
        return headerless(rows)
    }

    /// Which app the header looks like, for the summary line.
    private static func source(of header: [String], columns: [Column: Int]) -> String {
        let titles = Set(header.map(fold))
        if titles.isSuperset(of: ["bindername", "scryfallid", "manaboxid", "quantity"]) { return "ManaBox CSV" }
        if titles.contains("tradelistcount") { return titles.contains("editioncode") || titles.contains("cardnumber") ? "Deckbox CSV" : "Moxfield CSV" }
        if titles.contains("foldername"), titles.contains("pricebought") { return "Dragon Shield CSV" }
        if titles.contains("simplename") || titles.contains("sku") { return "TCGplayer CSV" }
        if titles.contains("quantityx") { return "Delver Lens CSV" }
        if titles.contains("cardname"), titles.contains("isfoil") { return "Deckstats CSV" }
        if titles.contains("setid"), titles.contains("variation") { return "MTGGoldfish CSV" }
        if titles.contains("editionname"), titles.contains("multiverseid") || titles.contains("scryfallid") { return "Archidekt CSV" }
        return "Spreadsheet"
    }

    private static func table(rows: [[String]], columns: [Column: Int], source: String) -> CardListFile {
        var file = CardListFile(kind: .table(source: source))
        func value(_ fields: [String], _ column: Column) -> String {
            guard let i = columns[column], i < fields.count else { return "" }
            return fields[i].trimmingCharacters(in: .whitespaces)
        }
        for fields in rows {
            let name = value(fields, .name)
            guard !name.isEmpty else { continue }
            var card = ImportedCard(quantity: 1, name: cleanName(name))

            let setCode = value(fields, .setCode)
            if looksLikeSetCode(setCode), Int(setCode) == nil { card.setCode = setCode.lowercased() }
            let setName = value(fields, .setName)
            if !setName.isEmpty { card.setName = setName }
            // "Set" / "Edition" alone: a code if it is written like one.
            let set = value(fields, .set)
            if !set.isEmpty {
                if card.setCode == nil, looksLikeSetCode(set) { card.setCode = set.lowercased() }
                else if card.setName == nil { card.setName = set }
            }
            let collector = value(fields, .collectorNumber)
            if !collector.isEmpty { card.collectorNumber = cleanNumber(collector) }
            let id = value(fields, .scryfallID).lowercased()
            if UUID(uuidString: id) != nil { card.scryfallID = id }

            card.finish = finish(value(fields, .finish))
            let condition = value(fields, .condition)
            if !condition.isEmpty { card.condition = Self.condition(condition) }
            card.language = language(value(fields, .language))
            if let price = number(in: value(fields, .price)), price > 0 { card.purchasePrice = price }
            let currency = value(fields, .currency).uppercased()
            if currency.count == 3 { card.purchaseCurrency = currency }

            // Counts: "4", "4x"; a file with no count column lists one a row.
            let regular = columns[.quantity] == nil ? 1 : (leadingInt(value(fields, .quantity)) ?? 0)
            let foils = leadingInt(value(fields, .foilQuantity)) ?? 0
            if regular <= 0, foils <= 0 {
                // A row with a name and a zero count is a row, not an error
                // (Deckbox lists wishlisted cards at 0).
                continue
            }
            if regular > 0 {
                card.quantity = regular
                file.cards.append(card)
            }
            // "Reg Qty" and "Foil Qty" side by side: two rows.
            if foils > 0 {
                var foil = card
                foil.quantity = foils
                foil.finish = .foil
                file.cards.append(foil)
            }
        }
        return file
    }

    /// Two columns, a count and a name, no header.
    private static func headerless(_ rows: [[String]]) -> CardListFile? {
        guard rows.allSatisfy({ $0.count >= 2 }) else { return nil }
        var file = CardListFile(kind: .table(source: "Spreadsheet"))
        var hits = 0
        for fields in rows {
            let a = fields[0].trimmingCharacters(in: .whitespaces), b = fields[1].trimmingCharacters(in: .whitespaces)
            if let count = leadingInt(a), count > 0, b.rangeOfCharacter(from: .letters) != nil, isCount(a) {
                file.cards.append(ImportedCard(quantity: count, name: cleanName(b))); hits += 1
            } else if let count = leadingInt(b), count > 0, a.rangeOfCharacter(from: .letters) != nil, isCount(b) {
                file.cards.append(ImportedCard(quantity: count, name: cleanName(a))); hits += 1
            } else {
                file.unparsed.append(fields.joined(separator: ", "))
            }
        }
        // Mostly counts and names, or it is a text list with commas in it
        // ("1 Thorin, Company's Leader").
        return hits > 0 && hits * 2 >= rows.count ? file : nil
    }

    // MARK: Values

    /// "4" or "4x", nothing else.
    private static func isCount(_ s: String) -> Bool {
        s.range(of: #"^\d+\s*[xX]?$"#, options: .regularExpression) != nil
    }

    static func leadingInt(_ s: String) -> Int? {
        let digits = s.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// "1,234.50", "$3.20", "3,20 €" → a number.
    static func number(in s: String) -> Double? {
        var t = String(s.unicodeScalars.filter { CharacterSet(charactersIn: "0123456789.,-").contains($0) })
        guard !t.isEmpty else { return nil }
        if t.contains(","), t.contains(".") {
            // The later of the two is the decimal mark.
            if t.lastIndex(of: ",")! > t.lastIndex(of: ".")! {
                t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                t = t.replacingOccurrences(of: ",", with: "")
            }
        } else if t.contains(",") {
            t = t.replacingOccurrences(of: ",", with: ".")
        }
        return Double(t)
    }

    /// Three to five letters and digits, written as a code ("M11", "plst").
    static func looksLikeSetCode(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9]{2,5}$"#, options: .regularExpression) != nil
    }

    /// TCGplayer hangs the treatment on the name: "Sol Ring (Borderless)".
    /// Kept as the card's name up to the parenthesis only when what is in
    /// it is a known treatment, never a card's own parentheses.
    static func cleanName(_ raw: String) -> String {
        // "Fire / Ice" is how some exports write a split card.
        let name = raw.contains(" // ") ? raw : raw.replacingOccurrences(of: " / ", with: " // ")
        guard let open = name.lastIndex(of: "("), name.hasSuffix(")"), open > name.startIndex else { return name }
        let inner = name[name.index(after: open)..<name.index(before: name.endIndex)].lowercased()
        let treatments = ["borderless", "extended art", "showcase", "foil etched", "retro frame", "full art", "alternate art",
                          "surge foil", "etched", "foil", "prerelease", "promo pack", "textured foil", "galaxy foil"]
        guard treatments.contains(where: { inner.contains($0) }) || Int(inner) != nil else { return name }
        return name[..<open].trimmingCharacters(in: .whitespaces)
    }

    /// "#141" and "141/280" → "141".
    static func cleanNumber(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("#") { s.removeFirst() }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func finish(_ raw: String) -> CardFinish {
        let v = raw.lowercased()
        if v.contains("etched") { return .etched }
        if v.isEmpty || v.contains("non") || ["normal", "regular", "false", "no", "0", "n"].contains(v) { return .normal }
        if v.contains("foil") || ["true", "yes", "1", "y", "f"].contains(v) { return .foil }
        return .normal
    }

    /// The condition vocabularies of the exporting apps, to ours.
    static func condition(_ raw: String) -> String {
        let v = String(raw.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
        switch v {
        case "mint", "m": return CardCondition.mint.rawValue
        case "nearmint", "nm", "nmm", "nmmint", "nearmintmint": return CardCondition.nearMint.rawValue
        case "lightlyplayed", "lightplayed", "lp", "excellent", "ex", "slightlyplayed", "sp", "goodlightlyplayed":
            return CardCondition.lightlyPlayed.rawValue
        case "moderatelyplayed", "mp", "played", "pl", "good", "gd", "veryfine":
            return CardCondition.moderatelyPlayed.rawValue
        case "heavilyplayed", "hp", "poor", "po":
            return CardCondition.heavilyPlayed.rawValue
        case "damaged", "dmg", "d":
            return CardCondition.damaged.rawValue
        default:
            return CardCondition.nearMint.rawValue
        }
    }

    /// A language written as a code or a name, to Scryfall's code.
    static func language(_ raw: String) -> String? {
        let v = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        if CardLanguage.codes.contains(v) { return v }
        switch v {
        case "english": return "en"
        case "spanish", "español", "sp": return "es"
        case "french", "français": return "fr"
        case "german", "deutsch": return "de"
        case "italian", "italiano": return "it"
        case "portuguese", "português", "pt-br": return "pt"
        case "japanese", "jp", "jpn": return "ja"
        case "korean", "kr": return "ko"
        case "russian": return "ru"
        case "chinese simplified", "simplified chinese", "s-chinese", "cs", "zh-cn", "zh": return "zhs"
        case "chinese traditional", "traditional chinese", "t-chinese", "ct", "zh-tw": return "zht"
        default: return nil
        }
    }
}
