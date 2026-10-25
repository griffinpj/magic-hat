//
//  PlaytestCard.swift
//  magic-hat
//
//  How the playtest table reads a card, once, from its type line, cost
//  and rules text: what each face is (a land is played, a permanent spell
//  resolves onto the battlefield, an instant or sorcery resolves into the
//  graveyard and never touches the table), how the card is laid out
//  (one face; a split card's two halves; an adventure; a modal
//  double-faced card whose back can be played; a transforming one whose
//  back can only be turned to), the keywords combat cares about, what it
//  taps for and whether it enters tapped. Then the cost of a spell and
//  how untapped sources pay it.
//
//  Shallow on purpose, like the goldfish's reading and its own: a few
//  patterns, no rules engine. Where it can't tell (an unhydrated card with
//  no type line, the back of a double-faced card whose cost Scryfall keeps
//  on the face) it leaves the player to it rather than guessing.
//

import Foundation

// MARK: - Faces

/// How a card's faces relate, inferred from its type line ("A // B"), its
/// images (a back image means a double-faced card) and its text.
nonisolated enum PlaytestLayout: Hashable, Sendable {
    case single
    /// Two halves on one card (Fire // Ice, Rooms): cast either.
    case split
    /// A creature or permanent with an Adventure: the adventure half goes to
    /// exile on resolution, and the card may be cast from there.
    case adventure
    /// A creature with an Omen: the omen half is shuffled into the library
    /// on resolution.
    case omen
    /// Modal double-faced: either face may be played (spell // land).
    case modal
    /// Transforming double-faced (and flip): only the front is cast; the
    /// back is what it turns into.
    case transform
}

nonisolated enum PlaytestKeyword: String, CaseIterable, Hashable, Sendable {
    case haste, vigilance, lifelink, defender, flying, trample, deathtouch, menace, reach, flash
    case doubleStrike = "double strike"
    case firstStrike = "first strike"
}

/// What a source adds when tapped with no other cost: one bit per colour
/// (`ManaColor.allCases` order) plus bit 5 for colourless, and how many.
nonisolated struct PlaytestManaSource: Hashable, Sendable {
    var mask: UInt8
    var units: Int

    static let colorless: UInt8 = 1 << 5
    static let anyColor: UInt8 = 0b1_1111

    static func bit(_ color: ManaColor) -> UInt8 {
        UInt8(1 << (ManaColor.allCases.firstIndex(of: color) ?? 0))
    }
}

/// One face of a card as the table reads it.
nonisolated struct PlaytestFace: Hashable, Sendable {
    let name: String
    let typeLine: String
    /// The face's mana cost; nil when the card doesn't say (a double-faced
    /// card's back — Scryfall keeps it on the face, which isn't stored).
    let cost: String?
    let isLand: Bool
    let isCreature: Bool
    let isArtifact: Bool
    let isEnchantment: Bool
    let isPlaneswalker: Bool
    let isBattle: Bool
    let isInstant: Bool
    let isSorcery: Bool
    let keywords: Set<PlaytestKeyword>
    let mana: PlaytestManaSource?
    let entersTapped: Bool

    /// A permanent card stays on the battlefield when it resolves. A face
    /// with no type we know (an unhydrated card) is treated as one, so it
    /// can still be put down; instants and sorceries never are.
    var isPermanent: Bool { !isInstant && !isSorcery }
    var isKnown: Bool { isLand || isCreature || isArtifact || isEnchantment || isPlaneswalker || isBattle || isInstant || isSorcery }

    /// The one word for what it is, for menus and VoiceOver.
    var kind: String {
        if isLand { return "Land" }
        if isCreature { return "Creature" }
        if isPlaneswalker { return "Planeswalker" }
        if isBattle { return "Battle" }
        if isInstant { return "Instant" }
        if isSorcery { return "Sorcery" }
        if isArtifact { return "Artifact" }
        if isEnchantment { return "Enchantment" }
        return "Card"
    }

    init(name: String, typeLine: String, cost: String?, text: String) {
        self.name = name
        self.typeLine = typeLine
        self.cost = cost
        let types = Set((typeLine.components(separatedBy: " — ").first ?? typeLine)
            .components(separatedBy: " - ").first?
            .split(separator: " ").map(String.init) ?? [])
        isLand = types.contains("Land")
        isCreature = types.contains("Creature")
        isArtifact = types.contains("Artifact")
        isEnchantment = types.contains("Enchantment")
        isPlaneswalker = types.contains("Planeswalker")
        isBattle = types.contains("Battle")
        isInstant = types.contains("Instant")
        isSorcery = types.contains("Sorcery")
        let rules = PlaytestReading.stripReminder(text)
        keywords = PlaytestReading.keywords(in: rules)
        mana = PlaytestReading.manaSource(typeLine: typeLine, text: text, name: name)
        entersTapped = PlaytestReading.entersTapped(text: rules, name: name)
    }
}

/// Everything about a card that doesn't change while it is played.
nonisolated struct PlaytestCardInfo: Hashable, Sendable {
    let layout: PlaytestLayout
    let front: PlaytestFace
    let back: PlaytestFace?
    let power: Int?
    let toughness: Int?
    let loyalty: Int?
    let noMaximumHandSize: Bool

    init(_ card: CardItem) {
        let names = card.name.components(separatedBy: " // ")
        let types = (card.typeLine ?? "").components(separatedBy: " // ")
        let costs = (card.manaCost ?? "").components(separatedBy: " // ")
        let whole = card.oracleText ?? ""
        let texts = PlaytestReading.faceTexts(whole, names: names)
        let lower = whole.lowercased()

        if types.count >= 2 {
            if card.backImageURL != nil {
                // Craft, disturb and meld turn a card over without the
                // word "transform" once reminder text is gone, and a
                // battle is always flipped when defeated; read as modal
                // they offered their back to be cast from hand.
                let turns = Self.turningWords.contains { lower.contains($0) } || types[0].contains("Battle")
                layout = turns ? .transform : .modal
            } else if types[1].contains("Adventure") {
                layout = .adventure
            } else if types[1].contains("Omen") {
                layout = .omen
            } else if lower.contains("flip it") || lower.contains("flip ~") {
                layout = .transform
            } else {
                layout = .split
            }
        } else {
            layout = .single
        }

        // No cost stored at all is an unhydrated card: unknown, not free.
        front = PlaytestFace(name: names.first ?? card.name, typeLine: types.first ?? "",
                             cost: card.manaCost == nil ? nil : costs[0],
                             text: texts.first ?? whole)
        if layout != .single, types.count >= 2 {
            back = PlaytestFace(name: names.count > 1 ? names[1] : card.name, typeLine: types[1],
                                cost: card.manaCost != nil && costs.count > 1 ? costs[1] : nil,
                                text: texts.count > 1 ? texts[1] : "")
        } else {
            back = nil
        }
        power = card.power.flatMap { Int($0) }
        toughness = card.toughness.flatMap { Int($0) }
        loyalty = card.loyalty.flatMap { Int($0) }
        noMaximumHandSize = lower.contains("you have no maximum hand size")
        disturbCost = layout == .transform && back != nil ? PlaytestReading.disturbCost(in: texts.first ?? whole) : nil
    }

    /// Words in a double-faced card's text that make it a transforming
    /// card rather than a modal one.
    static let turningWords = ["transform", "daybound", "nightbound", "convert", "craft with", "disturb", "meld", "incubate"]

    /// Disturb: the back may be cast, transformed, from the graveyard —
    /// and only from there — for this cost.
    let disturbCost: String?

    /// Whether the back can be played from hand: a modal card's other face,
    /// a split card's other half, an adventure or an omen.
    var backIsPlayable: Bool { back != nil && [.modal, .split, .adventure, .omen].contains(layout) }
    /// Whether the card turns over on the battlefield.
    var transforms: Bool { layout == .transform && back != nil }
}

// MARK: - Reading text

nonisolated enum PlaytestReading {
    /// A multi-faced card's oracle text as the store keeps it: each face's
    /// name on its own line, then its text, faces joined by "//". One
    /// string per face, the name line taken off.
    static func faceTexts(_ text: String, names: [String]) -> [String] {
        let parts = text.components(separatedBy: "\n\n//\n\n")
        guard parts.count > 1 else { return [text] }
        return parts.enumerated().map { i, part in
            guard i < names.count, part.hasPrefix(names[i] + "\n") else { return part }
            return String(part.dropFirst(names[i].count + 1))
        }
    }

    /// Text with parenthesised reminder text removed.
    static func stripReminder(_ text: String) -> String {
        var out = ""
        var depth = 0
        for ch in text {
            if ch == "(" { depth += 1; continue }
            if ch == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        return out
    }

    /// Words that make a line a keyword line ("Flying, haste", "Ward {2}").
    private static let keywordWords: [String] = PlaytestKeyword.allCases.map(\.rawValue) + [
        "hexproof", "indestructible", "ward", "protection", "shroud", "prowess", "changeling", "convoke",
        "cascade", "fear", "intimidate", "shadow", "skulk", "infect", "wither", "flanking", "exalted",
        "persist", "undying", "annihilator", "devoid", "partner", "toxic", "horsemanship", "banding",
        "storm", "affinity", "delve", "improvise", "evolve", "extort", "riot", "mentor", "ninjutsu",
        "training", "decayed", "unleash", "battle cry", "dethrone", "myriad", "melee", "afflict",
        "living weapon", "equip", "crew", "cycling", "kicker", "flashback", "rebound", "escape",
    ]

    /// The keywords a card has itself: read from keyword lines, so
    /// "creatures you control have haste." grants nothing here. A keyword
    /// line is one made only of keywords we know ("Flying, ward—Pay 3
    /// life.") or one with no sentence in it at all — no period, no colon —
    /// so a keyword the list lacks ("Flying, haste, backup 1") doesn't
    /// throw out the ones beside it.
    static func keywords(in text: String) -> Set<PlaytestKeyword> {
        var found = Set<PlaytestKeyword>()
        for line in text.lowercased().split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            let allKnown = parts.allSatisfy { part in
                part.hasSuffix("walk") || keywordWords.contains { part == $0 || part.hasPrefix($0 + " ") || part.hasPrefix($0 + "—") }
            }
            let isSentence = line.contains(".") || line.contains(":")
            guard allKnown || !isSentence else { continue }
            for part in parts { if let k = PlaytestKeyword(rawValue: part) { found.insert(k) } }
        }
        return found
    }

    /// "Disturb {1}{U}" on a keyword line: the cost, braces and all.
    static func disturbCost(in text: String) -> String? {
        for line in stripReminder(text).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("disturb ") else { continue }
            let cost = trimmed.dropFirst("disturb ".count).trimmingCharacters(in: .whitespaces)
            if cost.hasPrefix("{") { return cost }
        }
        return nil
    }

    /// "{T}: Add …" with nothing else in the cost (a Signet's "{1}, {T}" and
    /// a Treasure's "{T}, Sacrifice" are left to the player), plus the basic
    /// land types a land has. Nil when it makes no mana that way.
    static func manaSource(typeLine: String, text: String, name: String) -> PlaytestManaSource? {
        var mask: UInt8 = 0
        var units = 0
        let subtypes = typeLine.components(separatedBy: " — ").dropFirst().joined(separator: " ")
        let basics: [(String, ManaColor)] = [("Plains", .white), ("Island", .blue), ("Swamp", .black), ("Mountain", .red), ("Forest", .green)]
        for (basic, color) in basics where subtypes.contains(basic) {
            mask |= PlaytestManaSource.bit(color)
            units = 1
        }
        let lower = text.lowercased()
        var from = lower.startIndex
        while let r = lower.range(of: "{t}: add ", range: from..<lower.endIndex) {
            from = r.upperBound
            if r.lowerBound > lower.startIndex {
                let before = lower[lower.index(before: r.lowerBound)]
                guard before == "\n" || before == "(" else { continue }
            }
            let rest = lower[r.upperBound...]
            let end = rest.firstIndex(where: { $0 == "." || $0 == "\n" }) ?? rest.endIndex
            let (m, u) = readAdd(String(rest[..<end]))
            mask |= m
            units = max(units, u)
        }
        return units > 0 ? PlaytestManaSource(mask: mask, units: units) : nil
    }

    private static func readAdd(_ clause: String) -> (UInt8, Int) {
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5]
        if ["any color", "any one color", "any type", "chosen color", "any combination of colors"].contains(where: clause.contains) {
            let n = words.first { clause.hasPrefix($0.key + " mana") }?.value ?? 1
            var mask = PlaytestManaSource.anyColor
            if clause.contains("{c}") { mask |= PlaytestManaSource.colorless }
            return (mask, n)
        }
        let symbols = ManaSymbol.parse(clause)
        guard !symbols.isEmpty else { return (0, 0) }
        var mask: UInt8 = 0
        for symbol in symbols {
            let colors = symbol.colors
            if colors.isEmpty {
                if symbol.raw.uppercased() == "C" { mask |= PlaytestManaSource.colorless }
            } else {
                for color in colors { mask |= PlaytestManaSource.bit(color) }
            }
        }
        let units = clause.contains(" or ") ? 1 : symbols.count
        return (mask, units)
    }

    private static let tappedPattern = try! NSRegularExpression(pattern: #"enters (?:the battlefield )?tapped"#)
    private static let unlessPattern = try! NSRegularExpression(pattern: #"tapped unless|you may pay|if you don't|you may have"#)

    /// "This land enters tapped." / "Evolving Wilds enters the battlefield
    /// tapped." — about the card itself, with no clause that avoids it.
    static func entersTapped(text: String, name: String) -> Bool {
        let lower = text.lowercased()
        let range = NSRange(lower.startIndex..., in: lower)
        guard unlessPattern.firstMatch(in: lower, range: range) == nil else { return false }
        for match in tappedPattern.matches(in: lower, range: range) {
            guard let r = Range(match.range, in: lower) else { continue }
            let before = lower[..<r.lowerBound]
            let lead = before.split(whereSeparator: { $0 == "." || $0 == "\n" }).last.map(String.init) ?? String(before)
            let subject = lead.trimmingCharacters(in: .whitespaces)
            if subject.hasPrefix("this ") || subject == name.lowercased() || subject.hasPrefix(name.lowercased()) {
                return true
            }
        }
        return false
    }
}

// MARK: - Costs and paying them

/// A spell's mana cost as the payment reads it.
nonisolated struct PlaytestCost: Hashable, Sendable {
    /// Coloured pips, each the colours that pay it (a hybrid has two bits,
    /// `{C}` the colourless bit).
    var pips: [UInt8] = []
    /// Phyrexian pips: the colour, or 2 life.
    var phyrexian: [UInt8] = []
    /// {2/W}: the colour, or two generic.
    var twobrid: [UInt8] = []
    var generic = 0
    var hasX = false
    /// The cost as written, with any commander tax.
    let text: String
    /// False when the card doesn't state the cost (only the tax is known).
    var isKnown = true

    init(_ cost: String, tax: Int = 0) {
        for symbol in ManaSymbol.parse(cost) {
            let raw = symbol.raw.uppercased()
            if let n = Int(raw) { generic += n; continue }
            if raw == "X" || raw == "Y" || raw == "Z" { hasX = true; continue }
            if raw == "C" { pips.append(PlaytestManaSource.colorless); continue }
            if raw == "S" { generic += 1; continue }
            let mask = symbol.colors.reduce(UInt8(0)) { $0 | PlaytestManaSource.bit($1) }
            guard mask != 0 else { continue }
            if symbol.isPhyrexian { phyrexian.append(mask) }
            else if let first = symbol.parts.first, Int(first) != nil { twobrid.append(mask) }
            else { pips.append(mask) }
        }
        generic += tax
        text = tax > 0 ? (cost.isEmpty ? "{\(tax)}" : cost + " + {\(tax)}") : cost
    }

    var manaValue: Int { pips.count + phyrexian.count + twobrid.count + generic }
    var isFree: Bool { manaValue == 0 }
}

/// A source the payment may tap: what it makes, and how readily it is
/// tapped (lands first, then artifacts, creatures last; the narrowest
/// first within each, so duals stay up for the pips that need them).
nonisolated struct PlaytestPaySource: Hashable, Sendable {
    let id: UUID
    let mana: PlaytestManaSource
    let rank: Int
}

nonisolated struct PlaytestPayment: Hashable, Sendable {
    let tapped: [UUID]
    let lifePaid: Int
}

nonisolated enum PlaytestPayer {
    /// The sources to tap for `cost`, or nil when they can't pay it. Pips
    /// are matched to units of mana exactly (augmenting paths, the tightest
    /// pip first); generic is paid from what a tapped source has left
    /// over, then from the least flexible sources. Phyrexian pips fall back
    /// to life and twobrid pips to two generic when the colours aren't there.
    static func pay(_ cost: PlaytestCost, from sources: [PlaytestPaySource]) -> PlaytestPayment? {
        if cost.isFree { return PlaytestPayment(tapped: [], lifePaid: 0) }
        let ordered = sources.sorted {
            ($0.rank, $0.mana.mask.nonzeroBitCount, -$0.mana.units) < ($1.rank, $1.mana.mask.nonzeroBitCount, -$1.mana.units)
        }
        if let paid = attempt(pips: cost.pips + cost.phyrexian + cost.twobrid, generic: cost.generic, sources: ordered) {
            return PlaytestPayment(tapped: paid, lifePaid: 0)
        }
        if let paid = attempt(pips: cost.pips, generic: cost.generic + 2 * cost.twobrid.count, sources: ordered) {
            return PlaytestPayment(tapped: paid, lifePaid: 2 * cost.phyrexian.count)
        }
        return nil
    }

    private static func attempt(pips: [UInt8], generic: Int, sources: [PlaytestPaySource]) -> [UUID]? {
        var units: [(source: Int, mask: UInt8)] = []
        for (i, source) in sources.enumerated() {
            let mask = source.mana.mask == 0 ? PlaytestManaSource.colorless : source.mana.mask
            for _ in 0..<source.mana.units { units.append((i, mask)) }
        }
        guard units.count >= pips.count + generic else { return nil }
        let order = pips.indices.sorted { pips[$0].nonzeroBitCount < pips[$1].nonzeroBitCount }
        var owner = [Int?](repeating: nil, count: units.count)

        func augment(_ pip: Int, _ seen: inout [Bool]) -> Bool {
            for u in units.indices where !seen[u] && units[u].mask & pips[pip] != 0 {
                seen[u] = true
                if owner[u] == nil || augment(owner[u]!, &seen) {
                    owner[u] = pip
                    return true
                }
            }
            return false
        }
        for pip in order {
            var seen = [Bool](repeating: false, count: units.count)
            guard augment(pip, &seen) else { return nil }
        }
        var used = Set(units.indices.filter { owner[$0] != nil }.map { units[$0].source })
        var needed = generic
        // Leftovers of a source already tapped cost nothing more; then
        // colourless-only sources (they pay nothing else), the ones making
        // the most first, then the rest in the order they were ranked.
        let spare = units.indices.filter { owner[$0] == nil }.sorted { a, b in
            let (sa, sb) = (units[a].source, units[b].source)
            let key = { (s: Int) -> (Int, Int, Int, Int) in
                (used.contains(s) ? 0 : 1, sources[s].mana.mask & PlaytestManaSource.anyColor == 0 ? 0 : 1, -sources[s].mana.units, s)
            }
            return key(sa) < key(sb)
        }
        for u in spare where needed > 0 {
            owner[u] = -1
            used.insert(units[u].source)
            needed -= 1
        }
        guard needed == 0 else { return nil }
        return sources.indices.filter { used.contains($0) }.map { sources[$0].id }
    }
}

/// A cost in braces as words for a sentence: "{2}{G}{G}" → "2GG", and
/// "{2}{W} + {2}" (with tax) → "2W + 2".
nonisolated enum ManaText {
    static func plain(_ cost: String) -> String {
        let text = cost.replacingOccurrences(of: "}{", with: "").replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return text.isEmpty ? "0" : text
    }
}

// MARK: - Tokens

/// A token the table can create: one the deck's cards make (with the
/// catalog's printing when it has one), a common artifact token, or one
/// the player describes.
nonisolated struct PlaytestTokenTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// "Token Creature — Soldier".
    let typeLine: String
    let power: String?
    let toughness: String?
    let text: String
    let colors: [ManaColor]
    let imageURL: String?
    let artCropURL: String?
    /// The deck's cards that make it, for the sheet's subtitle.
    var makers: [String] = []

    init(id: String, name: String, typeLine: String, power: String? = nil, toughness: String? = nil, text: String = "",
         colors: [ManaColor] = [], imageURL: String? = nil, artCropURL: String? = nil, makers: [String] = []) {
        self.id = id; self.name = name; self.typeLine = typeLine; self.power = power; self.toughness = toughness
        self.text = text; self.colors = colors; self.imageURL = imageURL; self.artCropURL = artCropURL; self.makers = makers
    }

    init(_ token: DeckToken) {
        self.init(id: "deck-" + token.id, name: token.name,
                  typeLine: token.typeLine.isEmpty ? "Token" : token.typeLine,
                  power: token.power, toughness: token.toughness, text: token.oracleText ?? "",
                  colors: token.colors, imageURL: token.imageURL, artCropURL: token.artCropURL, makers: token.makers)
    }

    /// "Creature — Soldier · 1/1".
    var subtitle: String {
        var line = typeLine.replacingOccurrences(of: "Token ", with: "")
        if let power, let toughness { line += " · \(power)/\(toughness)" }
        return line
    }

    static let common: [PlaytestTokenTemplate] = [
        PlaytestTokenTemplate(id: "common-treasure", name: "Treasure", typeLine: "Token Artifact — Treasure",
                              text: "{T}, Sacrifice this token: Add one mana of any color."),
        PlaytestTokenTemplate(id: "common-clue", name: "Clue", typeLine: "Token Artifact — Clue",
                              text: "{2}, Sacrifice this token: Draw a card."),
        PlaytestTokenTemplate(id: "common-food", name: "Food", typeLine: "Token Artifact — Food",
                              text: "{2}, {T}, Sacrifice this token: You gain 3 life."),
        PlaytestTokenTemplate(id: "common-blood", name: "Blood", typeLine: "Token Artifact — Blood",
                              text: "{1}, {T}, Discard a card, Sacrifice this token: Draw a card."),
    ]

    /// A creature token the player names: "2/2 Zombie".
    static func custom(name: String, power: Int, toughness: Int) -> PlaytestTokenTemplate {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let title = trimmed.isEmpty ? "Creature" : trimmed
        return PlaytestTokenTemplate(id: "custom-\(title)-\(power)-\(toughness)", name: title,
                                     typeLine: "Token Creature — \(title)", power: "\(power)", toughness: "\(toughness)")
    }
}

nonisolated extension CardItem {
    /// A token as a card the table and the viewer can show.
    init(token: PlaytestTokenTemplate) {
        self.id = "token-" + token.id
        self.scryfallID = token.id
        self.oracleID = nil
        self.name = token.name
        self.setCode = ""
        self.setName = ""
        self.collectorNumber = ""
        self.rarity = "token"
        self.quantity = 1
        self.finish = .normal
        self.condition = ""
        self.language = "en"
        self.addedDate = nil
        self.owned = false
        self.collectionName = ""
        self.imageURL = token.imageURL
        self.artCropURL = token.artCropURL
        self.aspectRatio = 488.0 / 680.0
        self.typeLine = token.typeLine
        self.manaCost = ""
        self.oracleText = token.text
        self.power = token.power
        self.toughness = token.toughness
        self.loyalty = nil
        self.colors = token.colors
        self.colorIdentity = token.colors
        self.artist = nil
        self.price = nil
        self.priceFoil = nil
        self.sortKey = Self.sortKey(for: token.name)
        self.collectorNumberValue = 0
        self.rarityRankValue = 0
        self.purchasePrice = nil
        self.legalities = nil
        self.edhrecRank = nil
        self.purchaseURIs = nil
    }
}
