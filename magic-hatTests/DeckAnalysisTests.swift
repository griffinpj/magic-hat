import Testing
import Foundation
@testable import magic_hat

/// The deck read against the rules of thumb: what a card does, what a
/// commander pays off, and the scores and bracket a list comes out with.
@Suite("DeckAnalysis")
struct DeckAnalysisTests {
    static func card(_ name: String, type: String, text: String = "", cost: String = "", colors: [String] = [], identity: [String]? = nil,
                     rank: Int? = nil, price: String? = nil) throws -> CardItem {
        var fields: [String: Any] = ["name": name, "type_line": type, "oracle_text": text, "mana_cost": cost, "colors": colors,
                                     "color_identity": identity ?? colors, "oracle_id": UUID().uuidString]
        if let rank { fields["edhrec_rank"] = rank }
        if let price { fields["prices"] = ["usd": price] }
        return try CardSearchQueryMatchingTests.item(fields)
    }

    static func row(_ card: CardItem, qty: Int = 1, board: DeckBoard = .main) -> DeckCardItem {
        DeckCardItem(id: UUID(), board: board, quantity: qty, card: card, builtQuantity: 0, availableQuantity: 0)
    }

    static func reading(_ card: CardItem, identity: [ManaColor] = [.white, .blue, .black, .red, .green]) -> CardReading {
        CardReading(card, identity: identity)
    }

    // MARK: Roles

    @Test func rolesAreReadFromRulesText() throws {
        let cultivate = try Self.reading(Self.card("Cultivate", type: "Sorcery", text: "Search your library for up to two basic land cards, reveal those cards, put one onto the battlefield tapped and the other into your hand, then shuffle.", cost: "{2}{G}", colors: ["G"]))
        #expect(cultivate.roles == [.ramp], "a land search is ramp, not a tutor: \(cultivate.roles)")
        let study = try Self.reading(Self.card("Rhystic Study", type: "Enchantment", text: "Whenever an opponent casts a spell, you may draw a card unless that player pays {1}.", cost: "{2}{U}", colors: ["U"]))
        #expect(study.roles == [.draw])
        let swords = try Self.reading(Self.card("Swords to Plowshares", type: "Instant", text: "Exile target creature. Its controller gains life equal to its power.", cost: "{W}", colors: ["W"]))
        #expect(swords.roles == [.removal])
        let wrath = try Self.reading(Self.card("Wrath of God", type: "Sorcery", text: "Destroy all creatures. They can't be regenerated.", cost: "{2}{W}{W}", colors: ["W"]))
        #expect(wrath.roles == [.wipes])
        let tutor = try Self.reading(Self.card("Demonic Tutor", type: "Sorcery", text: "Search your library for a card, put that card into your hand, then shuffle.", cost: "{1}{B}", colors: ["B"]))
        #expect(tutor.roles == [.tutors])
        let forest = try Self.reading(Self.card("Forest", type: "Basic Land — Forest"))
        #expect(forest.roles == [.lands] && forest.isLand && forest.isBasic && forest.sources == [.green])
        let signet = try Self.reading(Self.card("Azorius Signet", type: "Artifact", text: "{1}, {T}: Add {W}{U}.", cost: "{2}"))
        #expect(signet.roles == [.ramp] && signet.sources == [.white, .blue])
        let vanilla = try Self.reading(Self.card("Grizzly Bears", type: "Creature — Bear", cost: "{1}{G}", colors: ["G"]))
        #expect(vanilla.roles.isEmpty)
    }

    @Test func tagListsOverrideTheText() throws {
        let odd = try Self.card("Odd Ramp", type: "Creature — Elf", text: "Flying.", cost: "{G}", colors: ["G"])
        let tagged = CardReading(odd, identity: [.green], tags: ["ramp": [odd.oracleID!]])
        #expect(tagged.roles == [.ramp], "the tag list says ramp, whatever the text pattern thinks")
        let untagged = CardReading(odd, identity: [.green], tags: ["ramp": []])
        #expect(untagged.roles.isEmpty, "a list that is in and does not name the card wins over the pattern")
    }

    @Test func speedAndChaosFlags() throws {
        let sol = try Self.reading(Self.card("Sol Ring", type: "Artifact", text: "{T}: Add {C}{C}.", cost: "{1}"))
        #expect(sol.roles == [.ramp] && sol.isFastMana)
        let cultivate = try Self.reading(Self.card("Cultivate", type: "Sorcery", text: "Search your library for up to two basic land cards.", cost: "{2}{G}", colors: ["G"]))
        #expect(!cultivate.isFastMana, "three mana is not fast")
        let force = try Self.reading(Self.card("Force of Will", type: "Instant", text: "You may pay 1 life and exile a blue card from your hand rather than pay this spell's mana cost.\nCounter target spell.", cost: "{3}{U}{U}", colors: ["U"]))
        #expect(force.isCounterspell && force.isFreeInteraction)
        let warp = try Self.reading(Self.card("Time Warp", type: "Sorcery", text: "Target player takes an extra turn after this one.", cost: "{3}{U}{U}", colors: ["U"]))
        #expect(warp.isExtraTurn)
        let geddon = try Self.reading(Self.card("Armageddon", type: "Sorcery", text: "Destroy all lands.", cost: "{3}{W}", colors: ["W"]))
        #expect(geddon.isMassLandDenial)
        let moon = try Self.reading(Self.card("Blood Moon", type: "Enchantment", text: "Nonbasic lands are Mountains.", cost: "{2}{R}", colors: ["R"]))
        #expect(moon.isMassLandDenial, "by name")
    }

    @Test func anyColourSourcesFollowTheIdentity() throws {
        let tower = try Self.card("Command Tower", type: "Land", text: "{T}: Add one mana of any color in your commander's color identity.")
        #expect(CardReading(tower, identity: [.red, .white]).sources == [.red, .white])
        #expect(CardReading(tower, identity: [.blue]).sources == [.blue])
    }

    // MARK: Engine

    @Test func engineReadsTheCommanderAndOverlapCountsTouches() throws {
        let meren = try Self.card("Meren of Clan Nel Toth", type: "Legendary Creature — Human Shaman",
                                  text: "Whenever another creature you control dies, you get an experience counter.\nAt the beginning of your end step, choose target creature card in your graveyard. If that card's mana value is less than or equal to the number of experience counters you have, return it to the battlefield. Otherwise, put it into your hand.",
                                  cost: "{2}{B}{G}", colors: ["B", "G"])
        let engine = DeckAnalysis.engine(of: [meren])
        #expect(engine.contains("dies") && engine.contains("the graveyard"), "\(engine)")
        #expect(!engine.contains("Human"), "a type that the text does not name is not the engine")
        let altar = try Self.card("Ashnod's Altar", type: "Artifact", text: "Sacrifice a creature: Add {C}{C}.", cost: "{3}")
        let r = Self.reading(altar)
        #expect(r.overlap(with: engine) == 0, "sacrifice is not in this engine's labels")
        let grim = try Self.card("Grim Haruspex", type: "Creature — Human Wizard", text: "Whenever another nontoken creature you control dies, draw a card.", cost: "{2}{B}", colors: ["B"])
        #expect(Self.reading(grim).overlap(with: engine) == 1)
        let elfLord = try Self.card("Ezuri", type: "Legendary Creature — Elf Warrior", text: "Other Elf creatures you control get +1/+1.", cost: "{1}{G}{G}", colors: ["G"])
        let tribal = DeckAnalysis.engine(of: [elfLord])
        #expect(tribal.contains("Elf"), "\(tribal)")
        let elf = try Self.card("Llanowar Elves", type: "Creature — Elf Druid", text: "{T}: Add {G}.", cost: "{G}", colors: ["G"])
        #expect(Self.reading(elf).overlap(with: tribal) == 1, "the type line counts for a tribal engine")
    }

    // MARK: Scores

    /// A plain 100-card list: the floors met, no combos, no game changers.
    static func precon(commander: CardItem? = nil) throws -> [DeckCardItem] {
        var rows: [DeckCardItem] = []
        let cmdr = try commander ?? Self.card("Commander", type: "Legendary Creature — Human", text: "Whenever you gain life, draw a card.", cost: "{2}{W}{W}", colors: ["W"])
        rows.append(Self.row(cmdr, board: .commander))
        rows.append(Self.row(try Self.card("Plains", type: "Basic Land — Plains"), qty: 36))
        for i in 0..<10 { rows.append(Self.row(try Self.card("Rock \(i)", type: "Artifact", text: "{T}: Add {W}.", cost: "{2}"))) }
        for i in 0..<10 { rows.append(Self.row(try Self.card("Draw \(i)", type: "Sorcery", text: "Draw two cards.", cost: "{2}{W}", colors: ["W"]))) }
        for i in 0..<10 { rows.append(Self.row(try Self.card("Kill \(i)", type: "Instant", text: "Destroy target creature.", cost: "{1}{W}", colors: ["W"]))) }
        for i in 0..<2 { rows.append(Self.row(try Self.card("Wipe \(i)", type: "Sorcery", text: "Destroy all creatures.", cost: "{3}{W}{W}", colors: ["W"]))) }
        for i in 0..<2 { rows.append(Self.row(try Self.card("Tutor \(i)", type: "Sorcery", text: "Search your library for a card, put it into your hand, then shuffle.", cost: "{1}{W}", colors: ["W"]))) }
        for i in 0..<29 { rows.append(Self.row(try Self.card("Bear \(i)", type: "Creature — Bear", text: "Lifelink", cost: "{2}{W}", colors: ["W"], rank: 3000 + i))) }
        return rows
    }

    @Test func aPlainListRatesAsAPreconInBracketTwo() throws {
        let rows = try Self.precon()
        #expect(rows.reduce(0) { $0 + $1.quantity } == 100)
        let readings = DeckAnalysis.readings(for: rows, identity: [.white], tags: [:])
        var signals = DeckAnalysisSignals.none
        signals.gameChangers = [:]
        signals.combos = DeckComboSet(included: [], near: [])
        let a = DeckAnalysis.compute(played: rows, format: .commander, identity: [.white], problems: [], signals: signals, readings: readings)
        #expect(a.isCommander && a.size == 100)
        #expect(a.shortRoles.isEmpty, "\(a.composition.map { "\($0.role): \($0.count)" })")
        #expect(a.sources.first?.count == 46, "36 Plains and 10 rocks: \(a.sources)")
        #expect(a.sources.first?.target == 29, "two white pips on the commander")
        #expect(a.bracket?.level == 2, "\(String(describing: a.bracket))")
        #expect(a.power.score >= 3.5 && a.power.score <= 6, "precon-ish power: \(a.power.score) \(a.power.parts.map { "\($0.key)=\($0.value)" })")
        #expect(a.playability.score >= 9, "floors met, sources met: \(a.playability.score) \(a.playability.parts.map { "\($0.key)=\($0.value)" })")
        #expect(a.impact.score < 5, "\(a.impact.score)")
        #expect(a.engine.contains("lifegain") && a.engine.contains("card draw"))
        #expect(a.medianRank != nil && a.rankedCards == 29, "only the bears carry a rank")
        #expect(a.combosChecked && a.gameChangersChecked && !a.tagsChecked)
        let bear = rows.first { $0.card.name == "Bear 0" }!
        #expect(a.rows[bear.card.id]?.touches == ["lifegain"])
    }

    @Test func combosGameChangersAndDenialMoveTheBracket() throws {
        let rows = try Self.precon()
        let readings = DeckAnalysis.readings(for: rows, identity: [.white], tags: [:])
        var signals = DeckAnalysisSignals.none
        let early = DeckCombo(id: "1", cards: ["Bear 0", "Bear 1"], produces: ["Infinite mana"], bracketTag: "R", manaNeeded: "{2}", popularity: 5, missing: nil)
        signals.combos = DeckComboSet(included: [early], near: [])
        signals.gameChangers = [:]
        let withCombo = DeckAnalysis.compute(played: rows, format: .commander, identity: [.white], problems: [], signals: signals, readings: readings)
        #expect(withCombo.bracket?.level == 4, "an early two-card combo is bracket 4: \(withCombo.bracket!.reasons)")
        #expect(withCombo.bracket!.reasons.contains { $0.hasPrefix("Two-card combos") })
        #expect(withCombo.power.score > 5, "\(withCombo.power.score)")
        #expect(withCombo.rows[rows.first { $0.card.name == "Bear 0" }!.card.id]?.combos.count == 1)

        signals.combos = DeckComboSet(included: [], near: [])
        signals.gameChangers = Dictionary(uniqueKeysWithValues: rows.filter { $0.card.name.hasPrefix("Kill") }.prefix(2).map { ($0.card.oracleID!, $0.card.name) })
        let two = DeckAnalysis.compute(played: rows, format: .commander, identity: [.white], problems: [], signals: signals, readings: readings)
        #expect(two.bracket?.level == 3 && two.gameChangers.count == 2, "\(String(describing: two.bracket))")
        signals.gameChangers = Dictionary(uniqueKeysWithValues: rows.filter { $0.card.name.hasPrefix("Kill") }.prefix(4).map { ($0.card.oracleID!, $0.card.name) })
        let four = DeckAnalysis.compute(played: rows, format: .commander, identity: [.white], problems: [], signals: signals, readings: readings)
        #expect(four.bracket?.level == 4, "four game changers is past bracket 3")

        var denial = rows
        denial[5] = Self.row(try Self.card("Armageddon", type: "Sorcery", text: "Destroy all lands.", cost: "{3}{W}", colors: ["W"]))
        let mld = DeckAnalysis.compute(played: denial, format: .commander, identity: [.white], problems: [], signals: signals, readings: [:])
        #expect(mld.massLandDenial == ["Armageddon"] && mld.bracket?.level == 4)
    }

    @Test func nothingCheckedIsSaidNotHidden() throws {
        let rows = try Self.precon()
        let a = DeckAnalysis.compute(played: rows, format: .commander, identity: [.white], problems: [], signals: .none,
                                     readings: DeckAnalysis.readings(for: rows, identity: [.white], tags: [:]))
        #expect(!a.combosChecked && !a.gameChangersChecked)
        #expect(a.bracket?.signals.first { $0.label == "Game changers" }?.level == nil)
        #expect(a.bracket?.signals.first { $0.label == "Game changers" }?.text == "Could not be checked.")
        #expect(a.power.parts.first { $0.key == "combos" }?.text == "Could not be checked.")
        #expect(a.bracket?.level == 2)
    }

    @Test func shortListsAreCappedAndFloorsCost() throws {
        let rows = try Array(Self.precon().prefix(8))
        let a = DeckAnalysis.compute(played: rows, format: .commander, identity: [.white], problems: [], signals: .none,
                                     readings: DeckAnalysis.readings(for: rows, identity: [.white], tags: [:]))
        #expect(a.power.score <= 3 && a.playability.score <= 3)
        #expect(a.power.notes.contains { $0.contains("capped at 3") })
        #expect(a.power.penalty > 0, "below the floors")
        #expect(a.shortRoles.count >= 3)
    }

    @Test func playabilityCountsProblemsAndShortColours() throws {
        var rows = try Self.precon()
        rows.removeAll { $0.card.name.hasPrefix("Rock") }
        let problems = [DeckIssue(kind: .offIdentity, message: "x"), DeckIssue(kind: .tooMany, message: "y")]
        let a = DeckAnalysis.compute(played: rows, format: .commander, identity: [.white], problems: problems, signals: .none,
                                     readings: DeckAnalysis.readings(for: rows, identity: [.white], tags: [:]))
        #expect(a.playability.parts.first { $0.key == "rules" }?.value == -2)
        #expect(a.playability.parts.first { $0.key == "engine" }?.value == -1.5, "no ramp at all: \(a.playability.parts)")
        #expect(a.sources.first?.count == 36 && a.sources.first?.isShort == false)
    }

    @Test func aSixtyCardFormatReadsCompositionWithoutTheBracket() throws {
        let rows = try [Self.row(Self.card("Bolt", type: "Instant", text: "Lightning Bolt deals 3 damage to any target.", cost: "{R}", colors: ["R"]), qty: 4),
                        Self.row(Self.card("Mountain", type: "Basic Land — Mountain"), qty: 20)]
        let a = DeckAnalysis.compute(played: rows, format: .modern, identity: [.red], problems: [], signals: .none,
                                     readings: DeckAnalysis.readings(for: rows, identity: [.red], tags: [:]))
        #expect(!a.isCommander && a.bracket == nil)
        #expect(a.composition.first { $0.role == .removal }?.count == 4)
        #expect(a.sources.first?.target == nil, "Karsten's Commander numbers do not apply")
    }

    @Test func pipCountAndListing() {
        #expect(DeckAnalysis.pipCount("{1}{U}{U}{B}") == 4)
        #expect(DeckAnalysis.pipCount("") == 0)
        #expect(DeckAnalysis.list(["a"]) == "a" && DeckAnalysis.list(["a", "b"]) == "a and b" && DeckAnalysis.list(["a", "b", "c"]) == "a, b and c")
        #expect(DeckAnalysis.popularity(rank: 10) == 2 && DeckAnalysis.popularity(rank: 30000) == 0 && DeckAnalysis.popularity(rank: nil) == 0)
    }
}
