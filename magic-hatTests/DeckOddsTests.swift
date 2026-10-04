import Testing
import Foundation
@testable import magic_hat

/// The four odds tools, each on its own: exact draw odds, the goldfish
/// player and its tallies, the mana base arithmetic, the commander
/// finder's count. Reference values from the binomial coefficients by
/// hand (Python's `comb`), not from the code under test.
enum OddsFixtures {
    static func card(_ name: String, type: String, text: String = "", cost: String = "", colors: [String] = []) throws -> CardItem {
        try DeckAnalysisTests.card(name, type: type, text: text, cost: cost, colors: colors)
    }

    static func row(_ card: CardItem, qty: Int = 1, board: DeckBoard = .main) -> DeckCardItem {
        DeckAnalysisTests.row(card, qty: qty, board: board)
    }

    static func snapshot(_ rows: [DeckCardItem], format: DeckFormat = .commander, identity: [ManaColor] = [.green]) -> DeckSnapshot {
        DeckPlanTests.snapshot(rows, format: format, identity: identity)
    }

    static func forest() throws -> CardItem { try card("Forest", type: "Basic Land — Forest") }
    static func mountain() throws -> CardItem { try card("Mountain", type: "Basic Land — Mountain") }
    static func bears() throws -> CardItem { try card("Grizzly Bears", type: "Creature — Bear", cost: "{1}{G}", colors: ["G"]) }
}

@Suite("Hypergeometric")
struct HypergeometricTests {
    @Test func knownValues() {
        // Four-of in sixty, opening seven: the 39.9% every player knows.
        #expect(abs(Hypergeometric.atLeast(1, population: 60, successes: 4, draws: 7) - 0.39949963) < 1e-6)
        // 24 lands in sixty: exactly three in seven.
        #expect(abs(Hypergeometric.exactly(3, population: 60, successes: 24, draws: 7) - 0.30870426) < 1e-6)
        let distribution = Hypergeometric.distribution(population: 60, successes: 24, draws: 7)
        #expect(abs(distribution.reduce(0, +) - 1) < 1e-9, "a distribution sums to one")
        #expect(Hypergeometric.atLeast(0, population: 60, successes: 4, draws: 7) == 1)
        #expect(Hypergeometric.atLeast(5, population: 60, successes: 4, draws: 7) == 0, "more hits than copies")
        #expect(abs(Hypergeometric.atMost(0, population: 60, successes: 4, draws: 7) - (1 - 0.39949963)) < 1e-6)
    }

    @Test func drawOddsCountsCardsSeen() {
        #expect(DrawOdds.cardsSeen(byTurn: 1, onThePlay: true) == 7)
        #expect(DrawOdds.cardsSeen(byTurn: 1, onThePlay: false) == 8)
        #expect(DrawOdds.cardsSeen(byTurn: 4, onThePlay: true) == 10)
        let odds = DrawOdds(librarySize: 99, rows: [])
        // One copy in 99, ten cards seen: 10/99.
        #expect(abs(odds.chance(copies: 1, byTurn: 4, onThePlay: true) - 10.0 / 99) < 1e-9)
    }

    @Test func anyAndAllOfSeveralCards() {
        let a = DrawOdds.Row(id: "a", name: "A", copies: 1, isGroup: false, imageURL: nil)
        let b = DrawOdds.Row(id: "b", name: "B", copies: 1, isGroup: false, imageURL: nil)
        let odds = DrawOdds(librarySize: 99, rows: [a, b])
        let any = odds.chanceOfAny([a, b], byTurn: 4, onThePlay: true)
        #expect(abs(any - (1 - Hypergeometric.exactly(0, population: 99, successes: 2, draws: 10))) < 1e-9)
        let all = odds.chanceOfAll([a, b], byTurn: 4, onThePlay: true)
        #expect(abs(all - 0.00927644) < 1e-6, "both singletons in ten of 99: \(all)")
        #expect(abs(odds.chanceOfAll([a], byTurn: 4, onThePlay: true) - odds.chance(copies: 1, byTurn: 4, onThePlay: true)) < 1e-9)
        #expect(odds.chanceOfAll([], byTurn: 4, onThePlay: true) == 1)
    }

    @Test func rowsFromASnapshot() throws {
        let forest = try OddsFixtures.forest()
        let bears = try OddsFixtures.bears()
        let commander = try OddsFixtures.card("Boss", type: "Legendary Creature — Elf", cost: "{2}{G}", colors: ["G"])
        let snapshot = OddsFixtures.snapshot([
            OddsFixtures.row(commander, board: .commander),
            OddsFixtures.row(forest, qty: 30), OddsFixtures.row(bears, qty: 4),
        ])
        let odds = DrawOdds(snapshot: snapshot)
        #expect(odds.librarySize == 34, "the commander is not in the library")
        #expect(odds.rows.first?.isGroup == true && odds.rows.first?.copies == 30)
        #expect(odds.rows.map(\.name) == ["Any land", "Forest", "Grizzly Bears"])
    }
}

@Suite("Goldfish")
struct GoldfishTests {
    @Test func readsCards() throws {
        let sol = GoldfishCard(try OddsFixtures.card("Sol Ring", type: "Artifact", text: "{T}: Add {C}{C}.", cost: "{1}"))
        #expect(sol.isProducer && sol.manaAmount == 2 && sol.produces == 0 && !sol.isCreatureProducer && sol.isRamp)
        let signet = GoldfishCard(try OddsFixtures.card("Azorius Signet", type: "Artifact", text: "{1}, {T}: Add {W}{U}.", cost: "{2}"))
        #expect(signet.manaAmount == 1 && signet.produces == (GoldfishCard.bit(.white) | GoldfishCard.bit(.blue)), "a Signet nets one")
        let elf = GoldfishCard(try OddsFixtures.card("Llanowar Elves", type: "Creature — Elf Druid", text: "{T}: Add {G}.", cost: "{G}", colors: ["G"]))
        #expect(elf.isCreatureProducer && elf.manaAmount == 1 && elf.produces == GoldfishCard.bit(.green))
        let growth = GoldfishCard(try OddsFixtures.card("Rampant Growth", type: "Sorcery", text: "Search your library for a basic land card, put that card onto the battlefield tapped, then shuffle.", cost: "{1}{G}", colors: ["G"]))
        #expect(growth.fetchesLands == 1 && growth.fetchedTapped && !growth.isProducer && growth.isRamp)
        let lore = GoldfishCard(try OddsFixtures.card("Nature's Lore", type: "Sorcery", text: "Search your library for a Forest card, put that card onto the battlefield, then shuffle.", cost: "{1}{G}", colors: ["G"]))
        #expect(lore.fetchesLands == 1 && !lore.fetchedTapped)
        let claim = GoldfishCard(try OddsFixtures.card("Skyshroud Claim", type: "Sorcery", text: "Search your library for up to two Forest cards, put them onto the battlefield, then shuffle.", cost: "{3}{G}", colors: ["G"]))
        #expect(claim.fetchesLands == 2)
        let tower = GoldfishCard(try OddsFixtures.card("Command Tower", type: "Land", text: "{T}: Add one mana of any color in your commander's color identity."))
        #expect(tower.isLand && tower.produces == GoldfishCard.anyColor && tower.manaAmount == 1 && !tower.entersTapped)
        let guildgate = GoldfishCard(try OddsFixtures.card("Simic Guildgate", type: "Land — Gate", text: "Simic Guildgate enters tapped.\n{T}: Add {G} or {U}."))
        #expect(guildgate.entersTapped && guildgate.produces == (GoldfishCard.bit(.green) | GoldfishCard.bit(.blue)))
        let check = GoldfishCard(try OddsFixtures.card("Hinterland Harbor", type: "Land", text: "Hinterland Harbor enters tapped unless you control a Forest or an Island.\n{T}: Add {G} or {U}."))
        #expect(!check.entersTapped, "a land you can untap is played as untapped")
        let brainstorm = GoldfishCard(try OddsFixtures.card("Brainstorm", type: "Instant", text: "Draw three cards, then put two cards from your hand on top of your library in any order.", cost: "{U}", colors: ["U"]))
        #expect(brainstorm.draws == 3 && brainstorm.pips == [GoldfishCard.bit(.blue)] && brainstorm.generic == 0)
        let study = GoldfishCard(try OddsFixtures.card("Rhystic Study", type: "Enchantment", text: "Whenever an opponent casts a spell, you may draw a card unless that player pays {1}.", cost: "{2}{U}", colors: ["U"]))
        #expect(study.draws == 0, "a repeating trigger is not a draw on cast")
        let hybrid = GoldfishCard(try OddsFixtures.card("Kitchen Finks", type: "Creature — Ouphe", cost: "{1}{G/W}{G/W}", colors: ["G", "W"]))
        #expect(hybrid.pips.count == 2 && hybrid.pips[0] == (GoldfishCard.bit(.green) | GoldfishCard.bit(.white)) && hybrid.generic == 1 && hybrid.manaValue == 3)
        let phyrexian = GoldfishCard(try OddsFixtures.card("Gitaxian Probe", type: "Sorcery", cost: "{U/P}", colors: ["U"]))
        #expect(phyrexian.pips.isEmpty && phyrexian.generic == 0, "a Phyrexian pip is paid with life")
    }

    @Test func allLandsAlwaysHitsDrops() throws {
        let cards = Array(repeating: GoldfishCard(try OddsFixtures.forest()), count: 40)
        var config = GoldfishConfig()
        config.games = 200
        let r = Goldfish.run(cards, config: config)
        #expect(r.everyLandDrop[8] == 1 && r.landDrop[1] == 1)
        #expect(r.manaAvailable[3] == 3, "three untapped Forests by turn 3")
        #expect(r.mulligans[0] < 1, "seven lands is not a keep, so some hands mulligan")
    }

    @Test func noLandsNeverDoes() throws {
        let cards = Array(repeating: GoldfishCard(try OddsFixtures.bears()), count: 40)
        var config = GoldfishConfig()
        config.games = 100
        let r = Goldfish.run(cards, config: config)
        #expect(r.landDrop[1] == 0 && r.spellsCast[8] == 0 && r.deadCardsAtEnd > 0)
    }

    @Test func seededRunsRepeat() throws {
        let cards = Array(repeating: GoldfishCard(try OddsFixtures.forest()), count: 24) + Array(repeating: GoldfishCard(try OddsFixtures.bears()), count: 36)
        var config = GoldfishConfig()
        config.games = 300
        let a = Goldfish.run(cards, config: config)
        let b = Goldfish.run(cards, config: config)
        #expect(a == b)
        config.seed = 7
        let c = Goldfish.run(cards, config: config)
        #expect(c != a, "a different seed plays different games")
    }

    @Test func aReasonableDeckCastsAndSpendsMana() throws {
        let forest = GoldfishCard(try OddsFixtures.forest())
        let bears = GoldfishCard(try OddsFixtures.bears())
        let cards = Array(repeating: forest, count: 24) + Array(repeating: bears, count: 36)
        var config = GoldfishConfig()
        config.games = 2_000
        let r = Goldfish.run(cards, config: config)
        #expect(r.everyLandDrop[4] > 0.6 && r.everyLandDrop[4] < 0.95, "24 lands in 60 hits four drops most of the time: \(r.everyLandDrop[4])")
        #expect(r.colorStuck.allSatisfy { $0 == 0 }, "mono-green never lacks green")
        #expect(r.spellsCast[8] > 5, "two-drops get cast: \(r.spellsCast[8])")
        #expect(r.efficiency > 0.5 && r.efficiency <= 1)
        #expect(r.keptLands.reduce(0, +) > 0.999)
    }

    @Test func wrongColoursStick() throws {
        let mountain = GoldfishCard(try OddsFixtures.mountain())
        let bears = GoldfishCard(try OddsFixtures.bears())
        let cards = Array(repeating: mountain, count: 24) + Array(repeating: bears, count: 36)
        var config = GoldfishConfig()
        config.games = 500
        let r = Goldfish.run(cards, config: config)
        #expect(r.spellsCast[8] == 0 && r.colorStuck[3] > 0.9, "green spells on Mountains: \(r.colorStuck[3])")
    }

    @Test func commanderIsCastWithTax() throws {
        let forest = GoldfishCard(try OddsFixtures.forest())
        let boss = GoldfishCard(try OddsFixtures.card("Boss", type: "Legendary Creature — Elf", cost: "{2}{G}", colors: ["G"]), isCommander: true)
        let cards = [boss] + Array(repeating: forest, count: 40)
        var config = GoldfishConfig()
        config.games = 300
        let r = Goldfish.run(cards, config: config)
        #expect(r.commanderCastBy.count == 9 && r.commanderCastBy[3] == 1, "three Forests on turn 3 cast a three-drop commander: \(r.commanderCastBy)")
        #expect(r.commanderMeanTurn == 3)
    }

    @Test func rampComesFirstAndRocksTapAtOnce() throws {
        let forest = GoldfishCard(try OddsFixtures.forest())
        let sol = GoldfishCard(try OddsFixtures.card("Sol Ring", type: "Artifact", text: "{T}: Add {C}{C}.", cost: "{1}"))
        let big = GoldfishCard(try OddsFixtures.card("Big", type: "Creature — Wurm", cost: "{3}", colors: []))
        // Hand will be lands plus Sol Rings and three-drops: Sol Ring on
        // turn 1, the three-drop on turn 2 off Forest + Sol Ring.
        let cards = Array(repeating: forest, count: 20) + Array(repeating: sol, count: 20) + Array(repeating: big, count: 20)
        var config = GoldfishConfig()
        config.games = 500
        let r = Goldfish.run(cards, config: config)
        #expect(r.manaAvailable[2] > 3, "a turn-one Sol Ring makes turn two more than two mana: \(r.manaAvailable[2])")
        #expect(r.spellsCast[2] > 1)
    }
}

@Suite("ManaBase")
struct ManaBaseTests {
    @Test func chanceAndTargetBehave() {
        // No sources: never.
        #expect(ManaBase.chanceOfSources(0, pips: 1, turn: 2, deckSize: 99, pool: 38) == 0)
        // Every pool card a source: always, in the games the land drop was made.
        #expect(abs(ManaBase.chanceOfSources(38, pips: 1, turn: 2, deckSize: 99, pool: 38) - 1) < 1e-9)
        let one = ManaBase.sourcesNeeded(pips: 1, turn: 1, deckSize: 99, pool: 38)
        let two = ManaBase.sourcesNeeded(pips: 2, turn: 2, deckSize: 99, pool: 38)
        let late = ManaBase.sourcesNeeded(pips: 1, turn: 6, deckSize: 99, pool: 38)
        #expect(two > one, "two pips need more than one")
        #expect(late < one, "a six-drop can wait for its colour")
        #expect(one > 10 && one < 38, "a one-drop's single pip in 99 cards: \(one)")
        #expect(ManaBase.chanceOfSources(one, pips: 1, turn: 1, deckSize: 99, pool: 38) >= ManaBase.confidence)
        #expect(ManaBase.chanceOfSources(one - 1, pips: 1, turn: 1, deckSize: 99, pool: 38) < ManaBase.confidence)
    }

    @Test func karstenLandCount() {
        // 99 cards, average MV 3.0, no cheap ramp: 31.42 + 9.39 = 40.8.
        #expect(ManaBase.suggestedLands(deckSize: 99, averageManaValue: 3.0, cheap: 0, format: .commander) == 41)
        #expect(ManaBase.suggestedLands(deckSize: 99, averageManaValue: 3.0, cheap: 10, format: .commander) == 38)
        // 60 cards, MV 2.5: 19.59 + 4.75 = 24.3.
        #expect(ManaBase.suggestedLands(deckSize: 60, averageManaValue: 2.5, cheap: 0, format: .modern) == 24)
    }

    @Test func reportReadsAToyDeck() throws {
        let forest = try OddsFixtures.forest()
        let mountain = try OddsFixtures.mountain()
        let bears = try OddsFixtures.bears()
        let bolt = try OddsFixtures.card("Lightning Bolt", type: "Instant", text: "Lightning Bolt deals 3 damage to any target.", cost: "{R}", colors: ["R"])
        let signet = try OddsFixtures.card("Gruul Signet", type: "Artifact", text: "{1}, {T}: Add {R}{G}.", cost: "{2}")
        let rows = [OddsFixtures.row(forest, qty: 20), OddsFixtures.row(mountain, qty: 4), OddsFixtures.row(bears, qty: 20),
                    OddsFixtures.row(bolt, qty: 10), OddsFixtures.row(signet, qty: 1)]
        let r = ManaBase.report(snapshot: OddsFixtures.snapshot(rows, identity: [.red, .green]))
        #expect(r.deckSize == 55 && r.lands == 24 && r.cheapProducers == 1)
        let red = try #require(r.colors.first { $0.color == .red })
        let green = try #require(r.colors.first { $0.color == .green })
        #expect(red.sources == 5 && green.sources == 21, "Mountains and the Signet; Forests and the Signet")
        #expect(red.pips == 10 && green.pips == 20)
        #expect(red.demandName == "Lightning Bolt" && red.demandTurn == 1 && red.demandPips == 1)
        #expect(red.isShort && !green.isShort, "four Mountains cannot cast Bolt on turn one; \(red.target) wanted")
        #expect(red.chance < ManaBase.confidence && green.chance >= ManaBase.confidence)
        // The basics split moves Forests to Mountains.
        let mountains = try #require(r.basics.first { $0.color == .red })
        #expect(mountains.suggested > mountains.current && r.basics.reduce(0) { $0 + $1.suggested } == 24)
        // Basics are the split, not the sources list; the Signet is the one
        // non-basic source, and every green source is spare.
        #expect(r.sources.map(\.name) == ["Gruul Signet"])
        #expect(r.sources[0].holds.isEmpty && r.sources[0].colors == [.red, .green] && !r.sources[0].isLand)
        let forests = try #require(r.basics.first { $0.color == .green })
        #expect(forests.current == 20 && forests.suggested < 20)
        #expect(abs(r.untappedShare - 1) < 1e-9)
    }
}

@Suite("CommanderFinder")
struct CommanderFinderTests {
    @Test func averageDeckDecodes() throws {
        let json = """
        {"header":"Average Deck for Atraxa, Praetors' Voice","creature":24,"land":36,
         "deck":{"commander":["Atraxa, Praetors' Voice"],"commander_v2":[["Atraxa, Praetors' Voice",1]],
                 "cards":{"Artifact":[["Arcane Signet",1],["Sol Ring",1]],"Land":[["Forest",4],["Atraxa, Praetors' Voice",1]]}}}
        """
        let deck = try JSONDecoder().decode(EDHRECAverageDeck.self, from: Data(json.utf8))
        let names = deck.entries.map(\.name)
        #expect(names == ["Arcane Signet", "Sol Ring", "Forest"], "commander left out, sections in order: \(names)")
        #expect(deck.entries.last?.count == 4)
        // Round-trips through the cache's encoder.
        let again = try JSONDecoder().decode([EDHRECAverageDeck.Entry].self, from: JSONEncoder().encode(deck.entries))
        #expect(again == deck.entries)
    }

    @Test func scoreCountsCopiesByName() {
        let entries = [EDHRECAverageDeck.Entry(name: "Sol Ring", count: 1), EDHRECAverageDeck.Entry(name: "Forest", count: 8),
                       EDHRECAverageDeck.Entry(name: "Bloomvine Regent // Claim Territory", count: 1), EDHRECAverageDeck.Entry(name: "Cultivate", count: 1)]
        let owned = ["sol ring": 3, "forest": 5, "bloomvine regent": 1]
        let m = CommanderMatch.score(slug: "boss", name: "Boss", rank: 3, numDecks: 100, entries: entries, owned: owned)
        #expect(m.totalCopies == 11 && m.ownedCopies == 7, "\(m.ownedCopies) of \(m.totalCopies)")
        #expect(abs(m.share - 7.0 / 11) < 1e-9)
        #expect(m.missingLines.map(\.name) == ["Forest", "Cultivate"] && m.missingLines.first?.missing == 3)
        #expect(!m.commanderOwned)
        let owner = CommanderMatch.score(slug: "boss", name: "Boss", rank: 3, numDecks: 100, entries: entries, owned: ["boss": 1])
        #expect(owner.commanderOwned && owner.ownedCopies == 0)
    }
}
