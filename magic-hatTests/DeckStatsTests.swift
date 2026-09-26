import Testing
import Foundation
@testable import magic_hat

@Suite("DeckStats")
struct DeckStatsTests {
    static func item(_ fields: [String: Any], qty: Int = 1, board: DeckBoard = .main, built: Int = 0, available: Int = 0) throws -> DeckCardItem {
        let card = try CardSearchQueryMatchingTests.item(fields)
        return DeckCardItem(id: UUID(), board: board, quantity: qty, card: card, builtQuantity: built, availableQuantity: available)
    }

    @Test func curvePipsTypesAndProduction() throws {
        let items = try [
            Self.item(["name": "Commander", "type_line": "Legendary Creature — Dwarf", "mana_cost": "{3}{R}{W}", "colors": ["R", "W"], "color_identity": ["R", "W"], "prices": ["usd": "10"]], board: .commander, built: 1),
            Self.item(["name": "Bolt", "type_line": "Instant", "mana_cost": "{R}", "colors": ["R"], "prices": ["usd": "1"]], qty: 1, available: 1),
            Self.item(["name": "Wrath", "type_line": "Sorcery", "mana_cost": "{2}{W}{W}", "colors": ["W"]], qty: 1),
            Self.item(["name": "Mountain", "type_line": "Basic Land — Mountain", "colors": []], qty: 10, built: 10),
            Self.item(["name": "Plains", "type_line": "Basic Land — Plains", "colors": []], qty: 8),
            Self.item(["name": "Signet", "type_line": "Artifact", "mana_cost": "{2}", "colors": [], "oracle_text": "{T}: Add one mana of any color in your commander's color identity."], qty: 1),
            Self.item(["name": "Rock", "type_line": "Artifact", "mana_cost": "{1}", "colors": [], "oracle_text": "{T}: Add {C}."], qty: 1),
        ]
        let played = items
        let stats = DeckStats.compute(played: played, format: .commander, identity: [.white, .red], allItems: items)

        #expect(stats.copies == 23 && stats.landCopies == 18)
        #expect(stats.curve.first { $0.bucket == 1 }?.total == 2, "Bolt and Rock")
        #expect(stats.curve.first { $0.bucket == 4 }?.total == 1, "Wrath")
        #expect(stats.curve.first { $0.bucket == 5 }?.counts[.multicolor] == 1, "the commander")
        #expect(stats.pips[.red] == 2 && stats.pips[.white] == 3)
        #expect(stats.genericPips == 3 + 2 + 2 + 1)
        #expect(stats.production[.red] == 11, "ten Mountains plus the any-colour signet")
        #expect(stats.production[.white] == 9)
        #expect(stats.colorlessProduction == 1)
        #expect(stats.types.map(\.name) == ["Creature", "Artifact", "Instant", "Sorcery", "Land"], "the deck list's section order")
        #expect(abs(stats.averageManaValue - (5 + 1 + 4 + 2 + 1) / 5.0) < 0.001)
        #expect(stats.totalValue == 11)
        #expect(stats.builtCopies == 11 && stats.availableCopies == 1 && stats.missingCopies == 11)
        #expect(stats.issues.contains { $0.kind == .tooFew })
        #expect(!stats.issues.contains { $0.kind == .overMaxCopies }, "basic lands may repeat")
    }

    @Test func issuesFlagSingletonLegalityAndIdentity() throws {
        let items = try [
            Self.item(["name": "Commander", "type_line": "Legendary Creature", "colors": ["G"], "color_identity": ["G"]], board: .commander),
            Self.item(["name": "Twin", "type_line": "Creature", "colors": ["G"], "color_identity": ["G"]], qty: 2),
            Self.item(["name": "Banned", "type_line": "Sorcery", "colors": ["G"], "color_identity": ["G"], "legalities": ["commander": "banned"]]),
            Self.item(["name": "Off", "type_line": "Instant", "colors": ["U"], "color_identity": ["U"]]),
        ]
        let stats = DeckStats.compute(played: items, format: .commander, identity: [.green], allItems: items)
        #expect(stats.issues.contains { $0.kind == .overMaxCopies && $0.message.contains("Twin") })
        #expect(stats.issues.contains { $0.kind == .notLegal && $0.message.contains("Banned") })
        #expect(stats.issues.contains { $0.kind == .offIdentity && $0.message.contains("Off") })
        let none = DeckStats.compute(played: [], format: .commander, identity: [], allItems: [])
        #expect(none.issues.contains { $0.kind == .noCommander })
    }

    /// The singleton rule has exceptions, and they are printed on the
    /// cards: basic lands (snow included), "any number of", "up to nine".
    @Test func copyLimitsReadTheCardsOwnExceptions() throws {
        let nazgul = try Self.item(["name": "Nazgûl", "type_line": "Creature — Wraith", "colors": ["B"], "color_identity": ["B"],
                                    "oracle_text": "Deathtouch\nWhenever Nazgûl enters, the Ring tempts you.\nA deck can have up to nine cards named Nazgûl."], qty: 9)
        let tenNazgul = try Self.item(["name": "Nazgûl", "type_line": "Creature — Wraith", "colors": ["B"], "color_identity": ["B"],
                                       "oracle_text": "A deck can have up to nine cards named Nazgûl."], qty: 10)
        let rats = try Self.item(["name": "Relentless Rats", "type_line": "Creature — Rat", "colors": ["B"], "color_identity": ["B"],
                                  "oracle_text": "A deck can have any number of cards named Relentless Rats."], qty: 30)
        let snow = try Self.item(["name": "Snow-Covered Swamp", "type_line": "Basic Snow Land — Swamp", "colors": []], qty: 12)
        let twin = try Self.item(["name": "Twin", "type_line": "Creature", "colors": ["B"], "color_identity": ["B"]], qty: 2)

        #expect(DeckStats.copyLimit(for: nazgul.card, format: .commander) == 9)
        #expect(DeckStats.copyLimit(for: rats.card, format: .commander) == nil)
        #expect(DeckStats.copyLimit(for: snow.card, format: .commander) == nil)
        #expect(DeckStats.copyLimit(for: twin.card, format: .commander) == 1)
        #expect(DeckStats.copyLimit(for: twin.card, format: .modern) == 4)

        let ok = DeckStats.compute(played: [nazgul, rats, snow], format: .commander, identity: [.black], allItems: [nazgul, rats, snow])
        #expect(!ok.issues.contains { $0.kind == .overMaxCopies }, "\(ok.issues.map(\.message))")
        let bad = DeckStats.compute(played: [tenNazgul, twin], format: .commander, identity: [.black], allItems: [tenNazgul, twin])
        #expect(bad.issues.filter { $0.kind == .overMaxCopies }.count == 2)
        #expect(bad.issues.contains { $0.kind == .overMaxCopies && $0.message.contains("max 9") })
    }

    /// The banner names rules broken, not what a deck under construction
    /// still lacks.
    @Test func violationsLeaveOutWhatIsMerelyUnfinished() throws {
        let items = try [
            Self.item(["name": "Commander", "type_line": "Legendary Creature", "colors": ["G"], "color_identity": ["G"]], board: .commander),
            Self.item(["name": "Off", "type_line": "Instant", "colors": ["U"], "color_identity": ["U"]]),
            Self.item(["name": "Off Too", "type_line": "Instant", "colors": ["R"], "color_identity": ["R"]]),
        ]
        let stats = DeckStats.compute(played: items, format: .commander, identity: [.green], allItems: items)
        #expect(stats.issues.contains { $0.kind == .tooFew })
        #expect(stats.violations.allSatisfy { $0.kind == .offIdentity })
        #expect(stats.violationSummary == "2 outside colour identity")
        let empty = DeckStats.compute(played: [], format: .commander, identity: [], allItems: [])
        #expect(empty.violations.isEmpty, "no commander and no cards is unfinished, not broken")
    }

    @Test func primaryTypeGroupsLandsFirst() {
        #expect(DeckStats.primaryType(of: "Artifact Land") == "Land")
        #expect(DeckStats.primaryType(of: "Land Creature — Forest Dryad") == "Land")
        #expect(DeckStats.primaryType(of: "Legendary Artifact — Equipment") == "Artifact")
        #expect(DeckStats.primaryType(of: "Artifact Creature — Golem") == "Creature")
        #expect(DeckStats.primaryType(of: "Instant // Sorcery") == "Instant")
        #expect(DeckStats.primaryType(of: nil) == "Other")
    }
}
