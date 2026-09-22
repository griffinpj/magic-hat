//
//  DeckStats.swift
//  magic-hat
//
//  Everything the Stats tab shows, computed in one pass over the played
//  cards (commander + mainboard). Pure and nonisolated: DeckStore calls it
//  off the main actor, tests call it directly.
//

import Foundation

nonisolated enum ColorClass: String, CaseIterable, Hashable, Sendable, Codable {
    case white = "W", blue = "U", black = "B", red = "R", green = "G", multicolor = "M", colorless = "C"

    var label: String {
        switch self {
        case .multicolor: return "Multicolor"
        case .colorless: return "Colorless"
        default: return ManaColor(rawValue: rawValue)?.name ?? rawValue
        }
    }

    static func of(_ colors: [ManaColor]) -> ColorClass {
        switch colors.count {
        case 0: return .colorless
        case 1: return ColorClass(rawValue: colors[0].rawValue) ?? .colorless
        default: return .multicolor
        }
    }
}

nonisolated struct DeckIssue: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case tooFew, tooMany, overMaxCopies, notLegal, offIdentity, noCommander }
    let kind: Kind
    let message: String
    var id: String { message }
}

nonisolated struct DeckStats: Hashable, Sendable {
    struct CurveBar: Hashable, Sendable, Identifiable {
        let bucket: Int          // 0…7, where 7 means 7+
        let counts: [ColorClass: Int]
        var id: Int { bucket }
        var total: Int { counts.values.reduce(0, +) }
        var label: String { bucket >= 7 ? "7+" : String(bucket) }
    }
    struct Count: Hashable, Sendable, Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    let curve: [CurveBar]
    /// Coloured pips across all mana costs (hybrid counts each half).
    let pips: [ManaColor: Int]
    let genericPips: Int
    /// Colours the deck's lands and rocks can produce, by "Add {X}" text
    /// and basic land types.
    let production: [ManaColor: Int]
    let colorlessProduction: Int
    let types: [Count]
    let rarities: [Count]
    let averageManaValue: Double
    let medianManaValue: Double
    let totalManaValue: Int
    let copies: Int
    let landCopies: Int
    let target: Int?
    let totalValue: Double
    let builtValue: Double
    let missingValue: Double
    let builtCopies: Int
    let availableCopies: Int
    let missingCopies: Int
    let issues: [DeckIssue]

    static let empty = DeckStats(curve: [], pips: [:], genericPips: 0, production: [:], colorlessProduction: 0,
                                 types: [], rarities: [], averageManaValue: 0, medianManaValue: 0, totalManaValue: 0,
                                 copies: 0, landCopies: 0, target: nil, totalValue: 0, builtValue: 0, missingValue: 0,
                                 builtCopies: 0, availableCopies: 0, missingCopies: 0, issues: [])

    /// Card types in the order the deck list groups them.
    static let typeOrder = ["Creature", "Planeswalker", "Battle", "Instant", "Sorcery", "Artifact", "Enchantment", "Land", "Other"]

    static func glyph(forType type: String) -> String? {
        switch type {
        case "Creature", "Planeswalker", "Battle", "Instant", "Sorcery", "Artifact", "Enchantment", "Land": return type.lowercased()
        default: return nil
        }
    }

    /// Primary type of a type line, for grouping. Lands first: an artifact
    /// land or a land creature belongs with the lands.
    static func primaryType(of typeLine: String?) -> String {
        guard let typeLine, !typeLine.isEmpty else { return "Other" }
        let front = typeLine.components(separatedBy: " // ").first ?? typeLine
        let types = front.components(separatedBy: " — ").first ?? front
        if types.contains("Land") { return "Land" }
        for t in ["Creature", "Planeswalker", "Battle", "Instant", "Sorcery", "Artifact", "Enchantment"] where types.contains(t) {
            return t
        }
        return "Other"
    }

    static func compute(played: [DeckCardItem], format: DeckFormat, identity: [ManaColor], allItems: [DeckCardItem]) -> DeckStats {
        var buckets = [Int: [ColorClass: Int]]()
        var pips = [ManaColor: Int]()
        var generic = 0
        var production = [ManaColor: Int]()
        var colorlessProduction = 0
        var types = [String: Int]()
        var rarities = [String: Int]()
        var manaValues: [Int] = []
        var totalMV = 0
        var copies = 0, landCopies = 0
        var totalValue = 0.0, builtValue = 0.0, missingValue = 0.0
        var built = 0, available = 0, missing = 0
        var issues: [DeckIssue] = []
        let identitySet = Set(identity)

        for item in played {
            let card = item.card
            let qty = item.quantity
            copies += qty
            let type = primaryType(of: card.typeLine)
            types[type, default: 0] += qty
            if !card.rarity.isEmpty { rarities[card.rarity.capitalized, default: 0] += qty }
            let price = card.priceUSD ?? 0
            totalValue += price * Double(qty)
            builtValue += price * Double(item.builtQuantity)
            missingValue += price * Double(item.missingQuantity)
            built += item.builtQuantity
            available += min(item.availableQuantity, item.stillNeeded)
            missing += item.missingQuantity

            let symbols = ManaSymbol.parse(card.manaCost ?? "")
            let mv = ManaSymbol.manaValue(of: card.manaCost ?? "")
            if type == "Land" {
                landCopies += qty
            } else {
                for _ in 0..<qty { manaValues.append(mv) }
                totalMV += mv * qty
                let bucket = min(mv, 7)
                buckets[bucket, default: [:]][ColorClass.of(card.colors), default: 0] += qty
            }
            for symbol in symbols {
                if symbol.isGeneric, let n = Int(symbol.raw) { generic += n * qty; continue }
                let colors = symbol.colors
                if colors.isEmpty {
                    if let first = symbol.parts.first, let n = Int(first) { generic += n * qty }  // {2/W} generic half
                    continue
                }
                for color in colors { pips[color, default: 0] += qty }
            }

            let produced = producedColors(typeLine: card.typeLine, oracleText: card.oracleText)
            for color in produced.colors { production[color, default: 0] += qty }
            if produced.colorless { colorlessProduction += qty }

            // Legality and identity issues.
            let isBasicLand = (card.typeLine ?? "").hasPrefix("Basic Land")
            if !isBasicLand, qty > format.maxCopies {
                issues.append(DeckIssue(kind: .overMaxCopies, message: "\(card.name): \(qty) copies (max \(format.maxCopies))"))
            }
            if let key = format.legalityKey, let legal = card.legalities?[key], legal != "legal" {
                issues.append(DeckIssue(kind: .notLegal, message: "\(card.name) is not legal in \(format.label)"))
            }
            if format.hasCommander, !Set(card.colorIdentity).isSubset(of: identitySet) {
                issues.append(DeckIssue(kind: .offIdentity, message: "\(card.name) is outside the commander's colour identity"))
            }
        }

        if let target = format.cardTarget {
            if copies < target { issues.insert(DeckIssue(kind: .tooFew, message: "\(target - copies) cards short of \(target)"), at: 0) }
            if copies > target { issues.insert(DeckIssue(kind: .tooMany, message: "\(copies - target) cards over \(target)"), at: 0) }
        }
        if format.hasCommander, !played.contains(where: { $0.board == .commander }) {
            issues.insert(DeckIssue(kind: .noCommander, message: "No commander chosen"), at: 0)
        }

        let sortedMV = manaValues.sorted()
        let median: Double
        if sortedMV.isEmpty { median = 0 }
        else if sortedMV.count % 2 == 1 { median = Double(sortedMV[sortedMV.count / 2]) }
        else { median = Double(sortedMV[sortedMV.count / 2 - 1] + sortedMV[sortedMV.count / 2]) / 2 }

        return DeckStats(
            curve: (0...7).map { CurveBar(bucket: $0, counts: buckets[$0] ?? [:]) },
            pips: pips,
            genericPips: generic,
            production: production,
            colorlessProduction: colorlessProduction,
            types: typeOrder.compactMap { type in types[type].map { Count(name: type, count: $0) } },
            rarities: ["Common", "Uncommon", "Rare", "Mythic", "Special", "Bonus"].compactMap { rarity in
                rarities[rarity].map { Count(name: rarity, count: $0) }
            },
            averageManaValue: manaValues.isEmpty ? 0 : Double(totalMV) / Double(manaValues.count),
            medianManaValue: median,
            totalManaValue: totalMV,
            copies: copies,
            landCopies: landCopies,
            target: format.cardTarget,
            totalValue: totalValue,
            builtValue: builtValue,
            missingValue: missingValue,
            builtCopies: built,
            availableCopies: available,
            missingCopies: missing,
            issues: issues
        )
    }

    /// Colours a permanent can add: basic land types, and "Add {X}" /
    /// "Add one mana of any color" in its rules text.
    static func producedColors(typeLine: String?, oracleText: String?) -> (colors: Set<ManaColor>, colorless: Bool) {
        var colors = Set<ManaColor>()
        var colorless = false
        let types = typeLine ?? ""
        let basics: [(String, ManaColor)] = [("Plains", .white), ("Island", .blue), ("Swamp", .black), ("Mountain", .red), ("Forest", .green)]
        for (type, color) in basics where types.contains(type) { colors.insert(color) }
        guard let text = oracleText, text.contains("Add") else { return (colors, colorless) }
        for symbol in ManaSymbol.parse(text) {
            // Only symbols that follow "Add" produce; {T} costs don't.
            for color in symbol.colors { colors.insert(color) }
            if symbol.raw == "C" { colorless = true }
        }
        if text.contains("mana of any color") || text.contains("mana of any one color") {
            colors.formUnion(ManaColor.allCases)
        }
        return (colors, colorless)
    }
}
