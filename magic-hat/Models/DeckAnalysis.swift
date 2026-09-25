//
//  DeckAnalysis.swift
//  magic-hat
//
//  A deck read against the Commander rules of thumb, from oracle text in
//  the catalog: what each card does (lands / ramp / draw / removal / wipes
//  / tutors), the colours the mana base makes against Karsten's numbers,
//  the mechanics the commander pays off and how much of the list touches
//  them, the Commander Bracket signals (game changers, mass land denial,
//  extra turns, two-card combos, tutors), and three 1–10 scores — power,
//  impact, playability — each built from capped parts the screen can show.
//
//  Pure and nonisolated: DeckAnalysisController runs it off the main
//  actor, the swap planner re-runs it per candidate swap, and the tests
//  call it directly. What needs the network (the game-changer list,
//  Scryfall's oracle tags, Commander Spellbook's combos, Recommander's
//  meta scores) arrives as `DeckAnalysisSignals`; without them the text
//  patterns stand in and the analysis says what it could not check.
//

import Foundation

// MARK: - Text patterns

/// An NSRegularExpression, which is immutable and safe to share across
/// threads, wrapped so it can sit in a `static let` of a nonisolated type.
nonisolated struct TextPattern: @unchecked Sendable {
    private let regex: NSRegularExpression

    init(_ pattern: String) {
        // Patterns are literals in this file; a typo is a programmer error.
        regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Capture group 1 of every match.
    func captures(in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}

// MARK: - Roles

/// What a card does for a deck, with the usual floor a Commander list
/// keeps: 34 lands, 8 ramp, 8 draw, 8 removal, a wipe, a couple of tutors.
nonisolated enum CardRole: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case lands, ramp, draw, removal, wipes, tutors

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lands: return "Lands"
        case .ramp: return "Ramp"
        case .draw: return "Card draw"
        case .removal: return "Removal"
        case .wipes: return "Board wipes"
        case .tutors: return "Tutors"
        }
    }

    var floor: Int {
        switch self {
        case .lands: return 34
        case .ramp: return 8
        case .draw: return 8
        case .removal: return 8
        case .wipes: return 1
        case .tutors: return 2
        }
    }

    var systemImage: String {
        switch self {
        case .lands: return "mountain.2"
        case .ramp: return "arrow.up.right"
        case .draw: return "rectangle.portrait.on.rectangle.portrait"
        case .removal: return "xmark.circle"
        case .wipes: return "tornado"
        case .tutors: return "magnifyingglass"
        }
    }

    /// Scryfall's oracle tag for the role (`otag:ramp`), nil for lands.
    var oracleTag: String? {
        switch self {
        case .lands: return nil
        case .ramp: return "ramp"
        case .draw: return "draw"
        case .removal: return "removal"
        case .wipes: return "board-wipe"
        case .tutors: return "tutor"
        }
    }
}

/// The mechanics a commander can pay off, each with the text that shows a
/// card touches it and the Scryfall term that finds more of them.
nonisolated struct DeckMechanic: Hashable, Sendable {
    let label: String
    let pattern: TextPattern
    let scryfall: String

    static func == (a: DeckMechanic, b: DeckMechanic) -> Bool { a.label == b.label }
    func hash(into hasher: inout Hasher) { hasher.combine(label) }

    /// Specific mechanics first: the theme search takes the first few a
    /// card touches, and "card draw" describes half of Magic.
    static let all: [DeckMechanic] = [
        DeckMechanic(label: "+1/+1 counters", pattern: TextPattern(#"\+1/\+1 counter"#), scryfall: #"o:"+1/+1 counter""#),
        DeckMechanic(label: "lifegain", pattern: TextPattern(#"gain(?:s|ed)? (?:\d+ |x |that much |twice that much )?life|life you gain|lifelink"#), scryfall: #"(o:"gain life" or o:"life you gain" or o:lifelink)"#),
        DeckMechanic(label: "tokens", pattern: TextPattern(#"\btokens?\b"#), scryfall: "o:token"),
        DeckMechanic(label: "sacrifice", pattern: TextPattern(#"sacrifice"#), scryfall: "o:sacrifice"),
        DeckMechanic(label: "dies", pattern: TextPattern(#"\bdies\b|put into (?:a|your) graveyard from the battlefield|leaves the battlefield"#), scryfall: #"(o:dies or o:"leaves the battlefield")"#),
        DeckMechanic(label: "discard", pattern: TextPattern(#"discard"#), scryfall: "o:discard"),
        DeckMechanic(label: "the graveyard", pattern: TextPattern(#"graveyard"#), scryfall: "o:graveyard"),
        DeckMechanic(label: "equipment and auras", pattern: TextPattern(#"equip|\baura\b"#), scryfall: "(t:equipment or t:aura)"),
        DeckMechanic(label: "planeswalkers", pattern: TextPattern(#"planeswalker|loyalty"#), scryfall: "(t:planeswalker or o:planeswalker)"),
        DeckMechanic(label: "copying", pattern: TextPattern(#"\bcop(?:y|ies)\b"#), scryfall: "o:copy"),
        DeckMechanic(label: "small creatures", pattern: TextPattern(#"power (?:1 or less|2 or less)"#), scryfall: #"o:"power 2 or less""#),
        DeckMechanic(label: "artifacts", pattern: TextPattern(#"artifact"#), scryfall: "o:artifact"),
        DeckMechanic(label: "enchantments", pattern: TextPattern(#"enchantment"#), scryfall: "o:enchantment"),
        DeckMechanic(label: "instants and sorceries", pattern: TextPattern(#"instant|sorcery|noncreature spell"#), scryfall: #"(o:"instant or sorcery" or o:"noncreature spell")"#),
        DeckMechanic(label: "casting spells", pattern: TextPattern(#"whenever you cast|spells? you cast"#), scryfall: #"o:"whenever you cast""#),
        DeckMechanic(label: "lands", pattern: TextPattern(#"landfall|land enters|\blands?\b"#), scryfall: #"(o:landfall or o:"land enters")"#),
        DeckMechanic(label: "attacking", pattern: TextPattern(#"attacks?\b|combat damage"#), scryfall: #"(o:attacks or o:"combat damage")"#),
        DeckMechanic(label: "exile", pattern: TextPattern(#"exile"#), scryfall: "o:exile"),
        DeckMechanic(label: "entering the battlefield", pattern: TextPattern(#"enters(?: the battlefield)?\b"#), scryfall: "o:enters"),
        DeckMechanic(label: "card draw", pattern: TextPattern(#"draw"#), scryfall: "o:draw"),
    ]

    static let byLabel: [String: DeckMechanic] = Dictionary(all.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
}

// MARK: - One card, read

/// Everything the analysis needs to know about one card, read once from
/// its text (and Scryfall's tag lists when they are in).
nonisolated struct CardReading: Hashable, Sendable {
    let roles: Set<CardRole>
    /// Colours it adds — basic land types, "add {W} or {U}", any-colour —
    /// counted only for lands and ramp.
    let sources: Set<ManaColor>
    let isLand: Bool
    let isBasic: Bool
    let manaValue: Int
    let isFastMana: Bool
    let isFreeInteraction: Bool
    let isCounterspell: Bool
    let isExtraTurn: Bool
    let isMassLandDenial: Bool
    /// Mechanics (by label) the text or type line touches — what makes a
    /// card on-plan for a commander that cares about instants, say.
    let mechanics: Set<String>
    /// Mechanics the rules text alone touches — what the card itself
    /// cares about, for finding cards that share its theme.
    let textMechanics: Set<String>
    /// Lowercase words of the text and type line, for tribal overlap.
    let words: Set<String>
    let isLegendaryCreature: Bool

    private static let landSearch = TextPattern(#"search your library for (?:up to \w+ |an? |any number of )?(?:basic )?lands?(?: cards?)?\b|land cards?.*?(?:onto the battlefield|into your hand)"#)
    private static let ramp = TextPattern(#"add \{|add (?:one|two|three) mana|add an amount of mana|treasure token|mana of any (?:one )?colou?r"#)
    private static let draw = TextPattern(#"draws? (?:a|two|three|four|x|that many|(?:\w+ )?cards?)\b"#)
    private static let notDraw = TextPattern(#"discard a card|counter target"#)
    private static let removal = TextPattern(#"(?:destroy|exile) (?:target|another target|up to \w+ target)|deals? \d+ damage to (?:any target|target creature|target planeswalker|each opponent and each creature)|target creature gets? -\d+/-\d+|fights? (?:up to one )?target|counter target|(?:return|put) target (?:non\w+ )?(?:creature|permanent|artifact|enchantment)[^.]*?(?:to its owner's hand|on the bottom|into its owner's library)"#)
    private static let wipe = TextPattern(#"(?:destroy|exile) all|each creature (?:gets|deals|is)|all creatures get|damage to each creature|each player sacrifices|each (?:other )?creature"#)
    private static let notWipe = TextPattern(#"destroy all (?:artifacts|enchantments) you control"#)
    private static let tutor = TextPattern(#"search your library for"#)
    private static let counter = TextPattern(#"counter target"#)
    private static let extraTurn = TextPattern(#"take an extra turn|extra turn after this one"#)
    private static let mld = TextPattern(#"(?:destroy|exile|sacrifices?) all (?:\w+ )?lands|return all (?:\w+ )?lands|each player sacrifices (?:all|\w+) lands|lands don't untap|permanents don't untap during|nonbasic lands are mountains|players can't untap more than"#)
    private static let ratherThanPay = TextPattern(#"rather than pay|you may pay .* rather than"#)
    private static let free = TextPattern(#"rather than pay|without paying its mana cost|if you control a commander, you may cast this spell without paying"#)
    private static let addGroup = TextPattern(#"add ((?:\{[wubrg]\}(?:, | or | and/or | and )?)+)"#)
    private static let pip = TextPattern(#"\{([wubrg])\}"#)
    private static let word = TextPattern(#"([a-z][a-z'\-]+)"#)

    static let massLandDenialNames: Set<String> = [
        "armageddon", "ravages of war", "catastrophe", "jokulhaups", "obliterate", "decree of annihilation", "devastation",
        "winter orb", "static orb", "blood moon", "magus of the moon", "sunder", "upheaval", "cataclysm", "fall of the thran",
        "impending disaster", "wildfire", "burning of xinye", "destructive force", "keldon firebombers", "rising waters",
        "hokori, dust drinker", "stasis", "worldfire", "apocalypse", "boil", "boiling seas", "choke", "back to basics",
        "ruination", "price of progress", "tsunami", "flashfires", "global ruin", "epicenter", "desolation angel",
        "numot, the devastator", "bend or break", "myojin of infinite rage",
    ]

    /// Front-face name, lowercased: what combo lists and name lists use.
    static func frontName(_ name: String) -> String {
        (name.components(separatedBy: " // ").first ?? name).trimmingCharacters(in: .whitespaces).lowercased()
    }

    init(_ card: CardItem, identity: [ManaColor], tags: [String: Set<String>] = [:]) {
        let type = card.typeLine ?? ""
        let text = (card.oracleText ?? "").lowercased()
        let isLand = type.contains("Land")
        let oracle = card.oracleID ?? ""
        func tagged(_ tag: String) -> Bool? {
            guard let list = tags[tag] else { return nil }
            return list.contains(oracle)
        }
        var roles = Set<CardRole>()
        if isLand { roles.insert(.lands) }
        let landSearch = Self.landSearch.matches(text)
        if !isLand {
            if tagged("ramp") ?? (Self.ramp.matches(text) || landSearch) { roles.insert(.ramp) }
            if tagged("draw") ?? (Self.draw.matches(text) && !Self.notDraw.matches(text)) { roles.insert(.draw) }
            if tagged("removal") ?? Self.removal.matches(text) { roles.insert(.removal) }
            if tagged("board-wipe") ?? (Self.wipe.matches(text) && !Self.notWipe.matches(text)) { roles.insert(.wipes) }
            if tagged("tutor") ?? (Self.tutor.matches(text) && !landSearch) { roles.insert(.tutors) }
        }
        self.roles = roles
        self.isLand = isLand
        self.isBasic = type.hasPrefix("Basic ")
        let mv = ManaSymbol.manaValue(of: card.manaCost ?? "")
        self.manaValue = mv

        var sources = Set<ManaColor>()
        if roles.contains(.lands) || roles.contains(.ramp) {
            for (basic, color) in [("Plains", ManaColor.white), ("Island", .blue), ("Swamp", .black), ("Mountain", .red), ("Forest", .green)]
            where type.contains(basic) { sources.insert(color) }
            if text.contains("any color") || text.contains("any colour") || text.contains("any combination of colors") {
                sources.formUnion(identity)
            }
            for group in Self.addGroup.captures(in: text) {
                for letter in Self.pip.captures(in: group) {
                    if let color = ManaColor(rawValue: letter.uppercased()) { sources.insert(color) }
                }
            }
        }
        self.sources = sources

        let isRamp = roles.contains(.ramp)
        self.isFastMana = isRamp && !isLand && (
            (mv <= 1 && (type.contains("Artifact") || type.contains("Instant") || type.contains("Sorcery")))
            || (mv <= 2 && Self.ratherThanPay.matches(text))
        )
        let counters = Self.counter.matches(text)
        self.isCounterspell = counters
        self.isFreeInteraction = (roles.contains(.removal) || counters) && (mv == 0 || Self.free.matches(text))
        self.isExtraTurn = tagged("extra-turn") ?? Self.extraTurn.matches(text)
        self.isMassLandDenial = tagged("mass-land-denial")
            ?? (Self.massLandDenialNames.contains(Self.frontName(card.name)) || Self.mld.matches(text))

        let haystack = text + " " + type.lowercased()
        self.mechanics = Set(DeckMechanic.all.filter { $0.pattern.matches(haystack) }.map(\.label))
        self.textMechanics = Set(DeckMechanic.all.filter { $0.pattern.matches(text) }.map(\.label))
        self.words = Set(Self.word.captures(in: haystack))
        self.isLegendaryCreature = type.contains("Legendary") && type.contains("Creature")
    }

    /// How many of the engine's labels this card touches (0–3): a mechanic
    /// by its pattern, a creature type by the word.
    func overlap(with engine: [String]) -> Int {
        min(3, touches(engine).count)
    }

    func touches(_ engine: [String]) -> [String] {
        engine.filter { label in
            if DeckMechanic.byLabel[label] != nil { return mechanics.contains(label) }
            let w = label.lowercased()
            return words.contains(w) || words.contains(w + "s")
        }
    }
}

// MARK: - Signals from outside

/// A combo, from Commander Spellbook.
nonisolated struct DeckCombo: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let cards: [String]
    let produces: [String]
    let bracketTag: String
    let manaNeeded: String
    let popularity: Int
    /// For a one-card-away combo: the piece the list lacks.
    var missing: String?

    var isTwoCard: Bool { cards.count == 2 }
    /// Early-game by Spellbook's tag, or cheap enough to assemble early.
    var isEarly: Bool { ["R", "S"].contains(bracketTag) || DeckAnalysis.pipCount(manaNeeded) <= 6 }
    var title: String { cards.joined(separator: " + ") }
    var result: String? { produces.first.map { $0.prefix(1).lowercased() + $0.dropFirst() } }
}

nonisolated struct DeckComboSet: Hashable, Sendable, Codable {
    let included: [DeckCombo]
    /// One card away, most played first.
    let near: [DeckCombo]
}

/// What the network adds to a reading. Every part optional: the analysis
/// runs without any of it and says so.
nonisolated struct DeckAnalysisSignals: Hashable, Sendable {
    /// Oracle id → name of every Game Changer, from Scryfall.
    var gameChangers: [String: String]?
    /// Scryfall oracle tag → oracle ids ("ramp", "draw", "removal",
    /// "board-wipe", "tutor", "extra-turn", "mass-land-denial").
    var tags: [String: Set<String>] = [:]
    var combos: DeckComboSet?
    /// Oracle id → Recommander's co-occurrence score (0–1).
    var meta: [String: Double]?
    /// Oracle id → name for the meta's picks, so the catalog lookup can go
    /// by name (see DeckStore.items(oracleIDs:names:)).
    var metaNames: [String: String] = [:]

    static let none = DeckAnalysisSignals()

    static let allTags = ["ramp", "draw", "removal", "board-wipe", "tutor", "extra-turn", "mass-land-denial"]
    var tagsComplete: Bool { Self.allTags.allSatisfy { tags[$0] != nil } }
}

// MARK: - The analysis

nonisolated struct DeckAnalysis: Hashable, Sendable {
    struct CardRef: Hashable, Sendable, Identifiable {
        let id: String       // CardItem id (the deck row's)
        let name: String
        let quantity: Int
    }

    struct RoleCount: Hashable, Sendable, Identifiable {
        let role: CardRole
        let count: Int
        let cards: [CardRef]
        var id: String { role.rawValue }
        var floor: Int { role.floor }
        var short: Int { max(0, floor - count) }
        var isShort: Bool { count < floor }
    }

    struct ColorSource: Hashable, Sendable, Identifiable {
        let color: ManaColor
        let count: Int
        /// Karsten's number for the commander's pips, nil outside Commander.
        let target: Int?
        let cards: [CardRef]
        var id: String { color.rawValue }
        var isShort: Bool { target.map { count < $0 } ?? false }
    }

    struct ScorePart: Hashable, Sendable, Identifiable {
        let key: String
        let label: String
        let value: Double
        let max: Double
        let text: String
        var id: String { key }
    }

    struct Score: Hashable, Sendable {
        let score: Double
        let band: String
        let base: Double
        let penalty: Double
        let parts: [ScorePart]
        let notes: [String]
    }

    struct BracketSignal: Hashable, Sendable, Identifiable {
        let label: String
        /// The bracket this signal points to; nil when it could not be read.
        let level: Int?
        let text: String
        var id: String { label }
    }

    struct Bracket: Hashable, Sendable {
        let level: Int
        let name: String
        let reasons: [String]
        let signals: [BracketSignal]

        static let names = [1: "Exhibition", 2: "Core", 3: "Upgraded", 4: "Optimized", 5: "cEDH"]
    }

    /// What one row of the deck is doing for it.
    struct RowReading: Hashable, Sendable, Identifiable {
        let id: String
        let roles: [CardRole]
        let touches: [String]
        let isGameChanger: Bool
        let combos: [DeckCombo]
        let near: [DeckCombo]
    }

    let format: DeckFormat
    let isCommander: Bool
    let identity: [ManaColor]
    let size: Int
    let targetSize: Int?
    let composition: [RoleCount]
    let sources: [ColorSource]
    let problems: [DeckIssue]
    let engine: [String]
    let averageManaValue: Double
    let nonlandCopies: Int
    let fastMana: [String]
    let freeInteraction: [String]
    let counterspells: Int
    let gameChangers: [String]
    let massLandDenial: [String]
    let extraTurns: [String]
    let combos: [DeckCombo]
    let nearCombos: [DeckCombo]
    let power: Score
    let impact: Score
    let playability: Score
    let bracket: Bracket?
    let medianRank: Int?
    let rankedCards: Int
    let rows: [String: RowReading]
    let combosChecked: Bool
    let gameChangersChecked: Bool
    let tagsChecked: Bool
    let metaChecked: Bool

    var shortRoles: [RoleCount] { composition.filter(\.isShort) }
    var shortColors: [ColorSource] { sources.filter(\.isShort) }

    var rankBand: String? {
        guard let medianRank else { return nil }
        if medianRank <= 500 { return "Built from staples" }
        if medianRank <= 2000 { return "Mostly well-trodden" }
        if medianRank <= 8000 { return "Off the beaten track" }
        return "Its own thing"
    }

    // MARK: Helpers

    static func pipCount(_ mana: String) -> Int {
        ManaSymbol.parse(mana).reduce(0) { total, symbol in
            total + (Int(symbol.raw) ?? 1)
        }
    }

    /// Reads every card once, keyed by CardItem id.
    static func readings(for items: [DeckCardItem], identity: [ManaColor], tags: [String: Set<String>]) -> [String: CardReading] {
        var out: [String: CardReading] = [:]
        out.reserveCapacity(items.count)
        for item in items where out[item.card.id] == nil {
            out[item.card.id] = CardReading(item.card, identity: identity, tags: tags)
        }
        return out
    }

    /// The mechanics the commanders pay off, from their text and type line
    /// — a crude engine statement, enough to tell a sacrifice deck from a
    /// +1/+1 deck. A creature type named in the text counts (Elf, Zombie).
    static func engine(of commanders: [CardItem]) -> [String] {
        var found: [String] = []
        for card in commanders {
            let text = (card.oracleText ?? "").lowercased()
            for mechanic in DeckMechanic.all where mechanic.pattern.matches(text) && !found.contains(mechanic.label) {
                found.append(mechanic.label)
            }
            if let type = card.typeLine, let dash = type.range(of: " — ") {
                let subtypes = type[dash.upperBound...].components(separatedBy: " // ").first ?? ""
                for sub in subtypes.split(separator: " ").map(String.init) where !sub.isEmpty {
                    let pattern = TextPattern(#"\b"# + NSRegularExpression.escapedPattern(for: sub.lowercased()) + #"s?\b"#)
                    if pattern.matches(text), !found.contains(sub) { found.append(sub) }
                }
            }
        }
        return found
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    static func format(_ value: Double, _ digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    // MARK: Compute

    static func compute(snapshot: DeckSnapshot, signals: DeckAnalysisSignals, readings: [String: CardReading]? = nil) -> DeckAnalysis {
        let played = snapshot.playedItems
        let readings = readings ?? Self.readings(for: played, identity: snapshot.identity, tags: signals.tags)
        return compute(played: played, format: snapshot.format, identity: snapshot.identity,
                       problems: snapshot.stats.issues, signals: signals, readings: readings)
    }

    /// The whole reading over the played cards (commander + mainboard).
    /// `readings` must cover every card id in `played`; a missing one is
    /// read on the spot.
    static func compute(played: [DeckCardItem], format: DeckFormat, identity: [ManaColor], problems: [DeckIssue],
                        signals: DeckAnalysisSignals, readings: [String: CardReading]) -> DeckAnalysis {
        func reading(_ item: DeckCardItem) -> CardReading {
            readings[item.card.id] ?? CardReading(item.card, identity: identity, tags: signals.tags)
        }
        let commanders = played.filter { $0.board == .commander }
        let isCommander = format.hasCommander && !commanders.isEmpty
        let engine = engine(of: commanders.map(\.card))
        let target = format.cardTarget

        var counts: [CardRole: Int] = [:]
        var byRole: [CardRole: [CardRef]] = [:]
        var sourceCounts: [ManaColor: Int] = [:]
        var bySource: [ManaColor: [CardRef]] = [:]
        var size = 0, nonland = 0, totalMV = 0
        var fast: [String] = [], free: [String] = [], counters = 0
        var gc: [String] = [], mld: [String] = [], extra: [String] = []
        var ranks: [Int] = []
        var rows: [String: RowReading] = [:]
        let gcList = signals.gameChangers
        let front = CardReading.frontName
        var comboOf: [String: [DeckCombo]] = [:]
        for combo in signals.combos?.included ?? [] { for name in combo.cards { comboOf[front(name), default: []].append(combo) } }
        var nearOf: [String: [DeckCombo]] = [:]
        for combo in signals.combos?.near ?? [] {
            for name in combo.cards where front(name) != front(combo.missing ?? "") { nearOf[front(name), default: []].append(combo) }
        }

        for item in played {
            let card = item.card
            let qty = item.quantity
            size += qty
            let r = reading(item)
            if !r.isBasic, let rank = card.edhrecRank, rank > 0 { ranks.append(rank) }
            let key = front(card.name)
            let isGC = card.oracleID.flatMap { gcList?[$0] } != nil
            if isGC, !gc.contains(card.name) { gc.append(card.name) }
            if item.board == .commander {
                rows[card.id] = RowReading(id: card.id, roles: [], touches: [], isGameChanger: isGC, combos: comboOf[key] ?? [], near: nearOf[key] ?? [])
                continue
            }
            let ref = CardRef(id: card.id, name: card.name, quantity: qty)
            for role in r.roles { counts[role, default: 0] += qty; byRole[role, default: []].append(ref) }
            for color in r.sources { sourceCounts[color, default: 0] += qty; bySource[color, default: []].append(ref) }
            if !r.isLand { nonland += qty; totalMV += r.manaValue * qty }
            if r.isFastMana { fast.append(card.name) }
            if r.isFreeInteraction { free.append(card.name) }
            if r.isCounterspell { counters += qty }
            if r.isMassLandDenial { mld.append(card.name) }
            if r.isExtraTurn { extra.append(card.name) }
            rows[card.id] = RowReading(id: card.id, roles: CardRole.allCases.filter { r.roles.contains($0) },
                                       touches: Array(r.touches(engine).prefix(3)), isGameChanger: isGC,
                                       combos: comboOf[key] ?? [], near: nearOf[key] ?? [])
        }

        let composition = CardRole.allCases.map { role in
            RoleCount(role: role, count: counts[role] ?? 0, cards: Array((byRole[role] ?? []).prefix(60)))
        }
        // Karsten: ~22 sources for a colour the commander needs one pip of,
        // ~29 for two or more.
        var pips: [ManaColor: Int] = [:]
        for c in commanders {
            for symbol in ManaSymbol.parse(c.card.manaCost ?? "") {
                for color in symbol.colors { pips[color, default: 0] += 1 }
            }
        }
        let sources = identity.map { color in
            ColorSource(color: color, count: sourceCounts[color] ?? 0,
                        target: isCommander ? ((pips[color] ?? 1) >= 2 ? 29 : 22) : nil,
                        cards: Array((bySource[color] ?? []).prefix(60)))
        }
        let avg = nonland > 0 ? Double(totalMV) / Double(nonland) : 0
        let combos = signals.combos?.included ?? []
        let near = signals.combos?.near ?? []
        let two = combos.filter(\.isTwoCard)
        let early = two.filter(\.isEarly)

        let power = powerScore(counts: counts, avg: avg, nonland: nonland, size: size, fast: fast, free: free, counters: counters,
                               two: two, early: early, combos: combos, gc: gc, extra: extra, mld: mld,
                               gcKnown: gcList != nil, combosKnown: signals.combos != nil)
        let impact = impactScore(counts: counts, counters: counters, fast: fast, two: two, early: early, combos: combos,
                                 gc: gc, extra: extra, mld: mld, gcKnown: gcList != nil)
        let playability = playabilityScore(counts: counts, sources: sources, avg: avg, nonland: nonland,
                                           problems: problems, size: size, target: target ?? size)

        var bracket: Bracket?
        if isCommander && (format == .commander || format == .brawl) {
            let tutors = counts[.tutors] ?? 0
            let comboText = { (xs: [DeckCombo]) in list(xs.prefix(3).map(\.title)) }
            var sigs: [BracketSignal] = []
            sigs.append(BracketSignal(label: "Game changers", level: gcList == nil ? nil : (gc.count > 3 ? 4 : (gc.isEmpty ? 2 : 3)),
                                      text: gcList == nil ? "Could not be checked." : (gc.isEmpty ? "None." : "\(gc.count): \(list(gc))" + (gc.count > 3 ? ". Bracket 3 allows three." : "."))))
            sigs.append(BracketSignal(label: "Mass land denial", level: mld.isEmpty ? 2 : 4, text: mld.isEmpty ? "None." : list(mld) + "."))
            sigs.append(BracketSignal(label: "Two-card combos", level: !early.isEmpty ? 4 : (!two.isEmpty ? 3 : 2),
                                      text: signals.combos == nil ? "Could not be checked." : (!early.isEmpty ? "Early: \(comboText(early))." : (!two.isEmpty ? "Late-game: \(comboText(two))." : "None."))))
            sigs.append(BracketSignal(label: "Extra turns", level: extra.count >= 3 ? 4 : (extra.isEmpty ? 2 : 3),
                                      text: extra.isEmpty ? "None." : "\(extra.count): \(list(extra))" + (extra.count >= 3 ? ". Enough to chain." : ".")))
            sigs.append(BracketSignal(label: "Tutors", level: tutors >= 4 ? 3 : 2,
                                      text: tutors == 0 ? "None." : "\(tutors)" + (tutors >= 4 ? ". Bracket 2 keeps them sparse." : ".")))
            let longer = combos.count - two.count
            if signals.combos != nil, longer > 0 {
                sigs.append(BracketSignal(label: "Longer combos", level: nil, text: "\(longer) of three cards or more; they do not move the bracket."))
            }
            let level = max(2, sigs.compactMap(\.level).max() ?? 2)
            var reasons = sigs.filter { $0.level == level && level > 2 }.map { "\($0.label): \($0.text)" }
            if reasons.isEmpty { reasons = ["No game changers, no mass land denial, no extra turns, no two-card combos."] }
            bracket = Bracket(level: level, name: Bracket.names[level] ?? "", reasons: reasons, signals: sigs)
        }

        let sortedRanks = ranks.sorted()
        return DeckAnalysis(
            format: format, isCommander: isCommander, identity: identity, size: size, targetSize: target,
            composition: composition, sources: sources, problems: problems, engine: engine,
            averageManaValue: avg, nonlandCopies: nonland, fastMana: fast, freeInteraction: free, counterspells: counters,
            gameChangers: gc, massLandDenial: mld, extraTurns: extra, combos: combos, nearCombos: near,
            power: power, impact: impact, playability: playability, bracket: bracket,
            medianRank: sortedRanks.isEmpty ? nil : sortedRanks[sortedRanks.count / 2], rankedCards: sortedRanks.count,
            rows: rows,
            combosChecked: signals.combos != nil, gameChangersChecked: gcList != nil,
            tagsChecked: signals.tagsComplete, metaChecked: signals.meta != nil
        )
    }

    // MARK: Scores

    /// Power, 1–10: starts at 2 and adds capped parts — speed (the curve),
    /// fast mana, consistency, interaction, combos, power cards, extra
    /// turns and land denial; missing floors and an odd land count cost a
    /// little, and a list under 60 cards is capped at 3.
    static func powerScore(counts: [CardRole: Int], avg: Double, nonland: Int, size: Int, fast: [String], free: [String], counters: Int,
                           two: [DeckCombo], early: [DeckCombo], combos: [DeckCombo], gc: [String], extra: [String], mld: [String],
                           gcKnown: Bool, combosKnown: Bool) -> Score {
        var parts: [ScorePart] = []
        let speed: Double = avg <= 0 ? 0 : (avg <= 2.2 ? 2.5 : (avg <= 2.6 ? 2.0 : (avg <= 3.0 ? 1.5 : (avg <= 3.4 ? 1.0 : (avg <= 3.8 ? 0.6 : 0.3)))))
        parts.append(ScorePart(key: "speed", label: "Speed", value: speed, max: 2.5,
                               text: nonland > 0 ? "Average mana value \(format(avg)) across nonland cards." : "No nonland cards."))
        parts.append(ScorePart(key: "fast", label: "Fast mana", value: min(1.0, 0.25 * Double(fast.count)), max: 1.0,
                               text: fast.isEmpty ? "None." : "\(fast.count): \(list(Array(fast.prefix(4))))" + (fast.count > 4 ? "…" : ".")))
        let tutors = counts[.tutors] ?? 0, draw = counts[.draw] ?? 0, ramp = counts[.ramp] ?? 0, removal = counts[.removal] ?? 0
        let cons = min(1.0, 0.2 * Double(tutors)) + (draw >= 10 ? 0.5 : (draw >= 8 ? 0.3 : 0)) + (ramp >= 10 ? 0.5 : (ramp >= 8 ? 0.3 : 0))
        parts.append(ScorePart(key: "consistency", label: "Consistency", value: cons, max: 2.0, text: "\(tutors) tutors, \(draw) draw, \(ramp) ramp."))
        let inter = min(1.0, 0.1 * Double(removal + counters)) + (counters > 0 ? 0.25 : 0) + min(0.5, 0.25 * Double(free.count))
        parts.append(ScorePart(key: "interaction", label: "Interaction", value: inter, max: 1.75,
                               text: "\(removal) removal" + (counters > 0 ? ", \(counters) counterspells" : "") + (free.isEmpty ? "" : ", free: " + list(Array(free.prefix(3)))) + "."))
        let longer = max(0, combos.count - two.count)
        let win = (!early.isEmpty ? 1.5 + 0.5 * Double(min(2, early.count - 1)) : 0) + (early.isEmpty && !two.isEmpty ? 0.75 : 0) + min(0.5, 0.25 * Double(longer))
        parts.append(ScorePart(key: "combos", label: "Combos", value: min(2.5, win), max: 2.5,
                               text: !combosKnown ? "Could not be checked." : (!two.isEmpty
                                ? "\(two.count) two-card" + (early.isEmpty ? "" : " (\(early.count) early)") + (longer > 0 ? ", \(longer) longer." : ".")
                                : (longer > 0 ? "\(longer) longer combos, no two-card ones." : "None found."))))
        parts.append(ScorePart(key: "power_cards", label: "Power cards", value: min(1.5, 0.3 * Double(gc.count)), max: 1.5,
                               text: !gc.isEmpty ? "\(gc.count) game changers." : (gcKnown ? "No game changers." : "Could not be checked.")))
        let chaos = min(0.5, 0.25 * Double(extra.count)) + (mld.isEmpty ? 0 : 0.5)
        parts.append(ScorePart(key: "chaos", label: "Turns and lands", value: chaos, max: 1.0,
                               text: (extra.isEmpty ? "No extra turns" : "\(extra.count) extra turns") + (mld.isEmpty ? "." : ", mass land denial.")))
        var penalty = 0.0
        var notes: [String] = []
        let below = CardRole.allCases.filter { (counts[$0] ?? 0) < $0.floor }.count
        if below > 0 {
            penalty = min(0.75, 0.15 * Double(below))
            notes.append("Below \(below) of the composition floors: −\(format(penalty)).")
        }
        let lands = counts[.lands] ?? 0
        if lands > 0, lands < 32 || lands > 40 { penalty += 0.25; notes.append("\(lands) lands: −0.25.") }
        parts = parts.map { ScorePart(key: $0.key, label: $0.label, value: ($0.value * 100).rounded() / 100, max: $0.max, text: $0.text) }
        let base = 2.0
        var raw = base + parts.reduce(0) { $0 + $1.value } - penalty
        if size < 60 { raw = min(raw, 3.0); notes.append("Fewer than 60 cards: capped at 3.") }
        let score = max(1.0, min(10.0, (raw * 10).rounded() / 10))
        let band = score >= 9 ? "cEDH-adjacent" : (score >= 7.5 ? "High power" : (score >= 6 ? "Upgraded" : (score >= 4 ? "Precon level" : "Casual")))
        return Score(score: score, band: band, base: base, penalty: (penalty * 100).rounded() / 100, parts: parts, notes: notes)
    }

    /// Impact, 1–10: how hard the deck hits the table when it works —
    /// wipes, interaction density, combos, power cards, extra turns, land
    /// denial, fast mana, tutors. Starts at 1 and adds up.
    static func impactScore(counts: [CardRole: Int], counters: Int, fast: [String], two: [DeckCombo], early: [DeckCombo], combos: [DeckCombo],
                            gc: [String], extra: [String], mld: [String], gcKnown: Bool) -> Score {
        var parts: [ScorePart] = []
        let wipes = counts[.wipes] ?? 0, removal = counts[.removal] ?? 0, tutors = counts[.tutors] ?? 0
        parts.append(ScorePart(key: "wipes", label: "Board wipes", value: min(1.5, 0.5 * Double(wipes)), max: 1.5, text: "\(wipes) board wipe" + (wipes == 1 ? "." : "s.")))
        parts.append(ScorePart(key: "interaction", label: "Interaction", value: min(1.5, 0.1 * Double(removal + counters)), max: 1.5,
                               text: "\(removal) removal" + (counters > 0 ? ", \(counters) counterspells" : "") + "."))
        let longer = max(0, combos.count - two.count)
        let win = (!early.isEmpty ? 2.0 : (!two.isEmpty ? 1.25 : 0)) + min(0.5, 0.25 * Double(longer))
        parts.append(ScorePart(key: "combos", label: "Combos", value: min(2.5, win), max: 2.5,
                               text: !two.isEmpty ? "\(two.count) two-card" + (early.isEmpty ? "" : " (\(early.count) early)") + (longer > 0 ? ", \(longer) longer." : ".")
                                : (longer > 0 ? "\(longer) longer combos." : "None found.")))
        parts.append(ScorePart(key: "power_cards", label: "Power cards", value: min(1.5, 0.3 * Double(gc.count)), max: 1.5,
                               text: !gc.isEmpty ? "\(gc.count) game changers." : (gcKnown ? "No game changers." : "Could not be checked.")))
        parts.append(ScorePart(key: "turns", label: "Extra turns", value: min(1.0, 0.5 * Double(extra.count)), max: 1.0,
                               text: extra.isEmpty ? "None." : "\(extra.count): \(list(Array(extra.prefix(3))))."))
        parts.append(ScorePart(key: "mld", label: "Land denial", value: mld.isEmpty ? 0 : 1.0, max: 1.0, text: mld.isEmpty ? "None." : list(Array(mld.prefix(3))) + "."))
        parts.append(ScorePart(key: "fast", label: "Fast mana", value: min(1.0, 0.2 * Double(fast.count)), max: 1.0, text: fast.isEmpty ? "None." : "\(fast.count) pieces."))
        parts.append(ScorePart(key: "tutors", label: "Tutors", value: min(0.75, 0.15 * Double(tutors)), max: 0.75, text: "\(tutors) tutors."))
        parts = parts.map { ScorePart(key: $0.key, label: $0.label, value: ($0.value * 100).rounded() / 100, max: $0.max, text: $0.text) }
        let score = max(1.0, min(10.0, ((1.0 + parts.reduce(0) { $0 + $1.value }) * 10).rounded() / 10))
        let band = score >= 8 ? "Warps the table" : (score >= 6 ? "Demands answers" : (score >= 4 ? "Holds its own" : "Gentle"))
        return Score(score: score, band: band, base: 1.0, penalty: 0, parts: parts, notes: [])
    }

    /// Playability, 1–10: how reliably the deck does its thing. Starts at
    /// 10 and loses points for a land count outside 34–38, colour sources
    /// under Karsten's targets, a heavy curve, fewer than eight ramp or
    /// draw, and rules problems.
    static func playabilityScore(counts: [CardRole: Int], sources: [ColorSource], avg: Double, nonland: Int,
                                 problems: [DeckIssue], size: Int, target: Int) -> Score {
        var parts: [ScorePart] = []
        var notes: [String] = []
        let lands = counts[.lands] ?? 0
        let off: Double = lands == 0 ? 3.0 : Double(max(0, abs(lands - 36) - 2)) * 0.25
        parts.append(ScorePart(key: "lands", label: "Land count", value: -min(2.5, off), max: 2.5, text: "\(lands) lands; 34–38 is the comfortable range."))
        var short = 0.0
        var bits: [String] = []
        for s in sources { if let t = s.target, s.count < t { short += Double(t - s.count) / Double(t); bits.append("\(s.color.rawValue) \(s.count) of ~\(t)") } }
        let judged = sources.contains { $0.target != nil }
        parts.append(ScorePart(key: "colours", label: "Colour sources", value: -min(2.5, (3.0 * short * 100).rounded() / 100), max: 2.5,
                               text: !bits.isEmpty ? "Short: " + bits.joined(separator: ", ") + "." : (judged ? "Every colour meets its target." : "No commander to judge against.")))
        let curve: Double = nonland == 0 ? 0 : (avg <= 3.2 ? 0 : (avg <= 3.6 ? 0.5 : (avg <= 4.0 ? 1.0 : 1.5)))
        parts.append(ScorePart(key: "curve", label: "Curve", value: -curve, max: 1.5,
                               text: nonland > 0 ? "Average mana value \(format(avg))" + (curve > 0 ? ", on the heavy side." : ".") : "No nonland cards."))
        let ramp = counts[.ramp] ?? 0, draw = counts[.draw] ?? 0
        let eng = min(1.5, 0.2 * Double(max(0, 8 - ramp))) + min(1.5, 0.2 * Double(max(0, 8 - draw)))
        parts.append(ScorePart(key: "engine", label: "Ramp and draw", value: -((eng * 100).rounded() / 100), max: 3.0,
                               text: "\(ramp) ramp, \(draw) draw; 8 of each keeps hands live."))
        let rules = min(3.0, Double(problems.count))
        parts.append(ScorePart(key: "rules", label: "Rules", value: -rules, max: 3.0,
                               text: problems.isEmpty ? "A legal \(target)-card list." : "\(problems.count) problem" + (problems.count == 1 ? "" : "s") + " in the list."))
        var score = max(1.0, min(10.0, ((10.0 + parts.reduce(0) { $0 + $1.value }) * 10).rounded() / 10))
        if size < 60 { score = min(score, 3.0); notes.append("Fewer than 60 cards: capped at 3.") }
        let band = score >= 8.5 ? "Smooth" : (score >= 7 ? "Runs well" : (score >= 5 ? "Stumbles" : "Rough"))
        return Score(score: score, band: band, base: 10.0, penalty: 0, parts: parts, notes: notes)
    }

    /// How much of the world plays a card, from its EDHREC rank: a modest
    /// term that keeps a well-played build-around off the bottom of the
    /// swap table without outweighing a role the deck is short of.
    static func popularity(rank: Int?) -> Double {
        guard let rank, rank > 0 else { return 0 }
        if rank <= 1000 { return 2.0 }
        if rank <= 5000 { return 1.0 }
        if rank <= 20000 { return 0.5 }
        return 0
    }
}
