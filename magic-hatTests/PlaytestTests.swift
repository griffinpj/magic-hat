import Testing
import Foundation
@testable import magic_hat

/// The playtest table played by Magic's rules: the opening hand and London
/// mulligan (free in multiplayer and Brawl), who skips the first draw, a
/// land a turn, instants and sorceries resolving into the graveyard and
/// never onto the battlefield, every face of a multi-faced card where it
/// belongs, paying with the right sources, commander tax, summoning
/// sickness, combat, cleanup, tokens, counters and the library tools —
/// with copies conserved throughout. Multi-faced cards use the shapes
/// Scryfall really sends (taken from the bulk slice).
@Suite("Playtest")
struct PlaytestTests {
    // MARK: Cards

    static func card(_ name: String, _ type: String, cost: String? = "", text: String = "",
                     power: String? = nil, toughness: String? = nil, loyalty: String? = nil) throws -> CardItem {
        var fields: [String: Any] = ["name": name, "type_line": type, "oracle_text": text, "oracle_id": UUID().uuidString]
        if let cost { fields["mana_cost"] = cost }
        if let power { fields["power"] = power }
        if let toughness { fields["toughness"] = toughness }
        if let loyalty { fields["loyalty"] = loyalty }
        return try CardSearchQueryMatchingTests.item(fields)
    }

    /// A multi-faced card as Scryfall sends it: the top level carries the
    /// joined name and type line, the faces their own; a double-faced card
    /// has no top-level image (each face has one), cost or power.
    static func faces(_ faces: [(name: String, type: String, cost: String, text: String)], doubleFaced: Bool,
                      cost: String? = nil, power: String? = nil, toughness: String? = nil) throws -> CardItem {
        var fields: [String: Any] = [
            "name": faces.map(\.name).joined(separator: " // "),
            "type_line": faces.map(\.type).joined(separator: " // "),
            "oracle_id": UUID().uuidString,
            "card_faces": faces.map { face -> [String: Any] in
                var f: [String: Any] = ["name": face.name, "type_line": face.type, "mana_cost": face.cost, "oracle_text": face.text]
                if doubleFaced { f["image_uris"] = ["normal": "https://img/\(face.name)"] }
                return f
            },
        ]
        if !doubleFaced { fields["image_uris"] = ["normal": "https://img/split"] }
        if let cost { fields["mana_cost"] = cost }
        if let power { fields["power"] = power }
        if let toughness { fields["toughness"] = toughness }
        return try CardSearchQueryMatchingTests.item(fields)
    }

    static func forest() throws -> CardItem { try card("Forest", "Basic Land — Forest", text: "({T}: Add {G}.)") }
    static func island() throws -> CardItem { try card("Island", "Basic Land — Island", text: "({T}: Add {U}.)") }
    static func mountain() throws -> CardItem { try card("Mountain", "Basic Land — Mountain", text: "({T}: Add {R}.)") }
    static func plains() throws -> CardItem { try card("Plains", "Basic Land — Plains", text: "({T}: Add {W}.)") }
    static func shock() throws -> CardItem { try card("Shock", "Instant", cost: "{R}", text: "Shock deals 2 damage to any target.") }
    static func divination() throws -> CardItem { try card("Divination", "Sorcery", cost: "{2}{U}", text: "Draw two cards.") }
    static func bears() throws -> CardItem { try card("Grizzly Bears", "Creature — Bear", cost: "{1}{G}", power: "2", toughness: "2") }

    static func deck(_ cards: [(CardItem, Int)], commanders: [CardItem] = [], format: DeckFormat = .standard) -> DeckSnapshot {
        var rows = commanders.map { DeckAnalysisTests.row($0, board: .commander) }
        rows += cards.map { DeckAnalysisTests.row($0.0, qty: $0.1) }
        return DeckPlanTests.snapshot(rows, format: format)
    }

    /// Sixty cards: lands of three colours, instants, sorceries, creatures.
    static func standardDeck(extra: [(CardItem, Int)] = [], format: DeckFormat = .standard, commanders: [CardItem] = []) throws -> DeckSnapshot {
        deck([(try forest(), 8), (try island(), 8), (try mountain(), 8), (try shock(), 12), (try divination(), 12), (try bears(), 12)] + extra,
             commanders: commanders, format: format)
    }

    /// A game past its opening hand, on a seed.
    static func game(_ snapshot: DeckSnapshot, seed: UInt64 = 1, onThePlay: Bool = true) -> PlaytestState {
        var state = PlaytestState(snapshot: snapshot)
        var rng = SeededGenerator(seed: seed)
        state.setOnThePlay(onThePlay)
        state.newGame(using: &rng)
        state.keep()
        return state
    }

    /// A copy of `name` in hand, fetched from the library when none is.
    static func inHand(_ state: inout PlaytestState, _ name: String) throws -> UUID {
        if let card = state.hand.first(where: { $0.card.name == name }) { return card.id }
        let card = try #require(state.library.first { $0.card.name == name }, "\(name) in the library")
        let moved = state.move(card.id, to: .hand)
        #expect(moved)
        return card.id
    }

    /// A copy of `name` put onto the battlefield (not played: no land drop).
    @discardableResult
    static func onBattlefield(_ state: inout PlaytestState, _ name: String) throws -> UUID {
        let card = try #require((state.library + state.hand).first { $0.card.name == name }, "\(name) to put down")
        let moved = state.move(card.id, to: .battlefield)
        #expect(moved)
        return card.id
    }

    /// Ends the turn, discarding the first cards in hand if cleanup asks.
    static func passTurn(_ state: inout PlaytestState) {
        state.endTurn()
        while case .cleanup = state.phase, let first = state.hand.first { state.discard(first.id) }
    }

    // MARK: Opening hand

    @Test func startsWithEveryCopyInTheLibraryAndTheCommanderInCommand() throws {
        let captain = try Self.card("Captain", "Legendary Creature — Human", cost: "{2}{W}", power: "3", toughness: "3")
        let state = PlaytestState(snapshot: Self.deck([(try Self.plains(), 30), (try Self.shock(), 60)], commanders: [captain], format: .commander))
        #expect(state.librarySize == 90)
        #expect(state.command.count == 1 && state.command[0].isCommander)
        #expect(state.total == 91)
        #expect(state.isUntouched)
        #expect(state.phase == .opening && state.turn == 0)
        #expect(state.life == 40 && state.opponentLife == 40, "Commander starts at 40")
        #expect(PlaytestState(snapshot: try Self.standardDeck()).life == 20)
        #expect(PlaytestState(snapshot: try Self.standardDeck(format: .brawl)).life == 25)
    }

    @Test func theOpeningHandWaitsForAKeepAndNothingCanBePlayed() throws {
        var a = PlaytestState(snapshot: try Self.standardDeck())
        var b = a
        var ga = SeededGenerator(seed: 7), gb = SeededGenerator(seed: 7)
        a.newGame(using: &ga)
        b.newGame(using: &gb)
        #expect(a.hand.count == 7 && a.librarySize == 53)
        #expect(a.hand.map(\.card.name) == b.hand.map(\.card.name), "the seed repeats the shuffle")
        var gc = SeededGenerator(seed: 8)
        var c = PlaytestState(snapshot: try Self.standardDeck())
        c.newGame(using: &gc)
        #expect(c.library.map(\.card.name) != a.library.map(\.card.name), "another seed, another order")
        #expect(a.phase == .opening && a.turn == 0)
        let first = a.hand[0].id
        #expect(a.issue(playing: first) == .notMainPhase)
        #expect(a.play(first) == nil)
        #expect(a.hand.count == 7)
        a.keep()
        #expect(a.phase == .main && a.turn == 1)
        #expect(a.hand.count == 7, "on the play in a two-player game: no draw on turn one")
    }

    @Test func londonMulliganDrawsSevenThenBottomsOnePerMulligan() throws {
        var state = PlaytestState(snapshot: try Self.standardDeck())
        var rng = SeededGenerator(seed: 1)
        state.newGame(using: &rng)
        state.mulligan(using: &rng)
        #expect(state.hand.count == 7 && state.cardsToBottom == 1 && state.keepSize == 6)
        state.mulligan(using: &rng)
        #expect(state.hand.count == 7 && state.cardsToBottom == 2 && state.keepSize == 5)
        #expect(state.librarySize == 53)
        state.keep()
        #expect(state.phase == .bottoming(2))
        let first = state.hand[0].id, second = state.hand[1].id
        state.bottom(first)
        #expect(state.phase == .bottoming(1))
        #expect(state.library.last?.id == first)
        state.bottom(second)
        #expect(state.phase == .main && state.turn == 1)
        #expect(state.hand.count == 5)
        #expect(state.library.suffix(2).map(\.id) == [first, second])
        // Bottoming is over: a tap no longer bottoms.
        state.bottom(state.hand[0].id)
        #expect(state.hand.count == 5)
        #expect(state.total == 60)
        #expect(state.mulligans == 2)
    }

    @Test func theFirstMulliganIsFreeInCommanderOathbreakerAndBrawl() throws {
        for format in [DeckFormat.commander, .oathbreaker, .brawl] {
            var state = PlaytestState(snapshot: try Self.standardDeck(format: format))
            var rng = SeededGenerator(seed: 2)
            state.newGame(using: &rng)
            state.mulligan(using: &rng)
            #expect(state.cardsToBottom == 0 && state.keepSize == 7, "\(format)")
            state.mulligan(using: &rng)
            #expect(state.cardsToBottom == 1, "\(format)")
            state.keep()
            #expect(state.phase == .bottoming(1), "\(format)")
        }
        var standard = PlaytestState(snapshot: try Self.standardDeck())
        var rng = SeededGenerator(seed: 2)
        standard.newGame(using: &rng)
        standard.mulligan(using: &rng)
        #expect(standard.cardsToBottom == 1, "no free mulligan one on one")
    }

    @Test func onlyThePlayerOnThePlayInATwoPlayerGameSkipsTheFirstDraw() throws {
        #expect(Self.game(try Self.standardDeck(), onThePlay: true).hand.count == 7)
        #expect(Self.game(try Self.standardDeck(), onThePlay: false).hand.count == 8)
        #expect(Self.game(try Self.standardDeck(format: .commander), onThePlay: true).hand.count == 8, "multiplayer: everyone draws")
        var state = Self.game(try Self.standardDeck(), onThePlay: true)
        state.setOnThePlay(false)
        #expect(state.onThePlay, "the order is fixed once the game has begun")
    }

    // MARK: Casting

    @Test func instantsAndSorceriesResolveIntoTheGraveyardNeverOntoTheBattlefield() throws {
        var state = Self.game(try Self.standardDeck())
        let mountain = try Self.onBattlefield(&state, "Mountain")
        let shock = try Self.inHand(&state, "Shock")
        #expect(state.issue(playing: shock) == nil)
        let cast = state.play(shock)
        let result = try #require(cast)
        #expect(result.zone == .graveyard && result.tapped == 1 && !result.isLand)
        #expect(state.zone(of: shock) == .graveyard)
        #expect(state.battlefield.map(\.id) == [mountain], "the instant is not a permanent")
        #expect(state.card(mountain)?.isTapped == true, "paid with the Mountain")
        #expect(state.log.last?.isNotable == true, "the table says where it went")
        let putDown = state.move(shock, to: .battlefield)
        #expect(putDown == false, "an instant can't be put onto the battlefield")
        #expect(state.zone(of: shock) == .graveyard)

        let divination = try Self.inHand(&state, "Divination")
        #expect(state.issue(playing: divination) == .cannotPay(cost: "{2}{U}", available: 0))
        let unforced = state.play(divination)
        #expect(unforced == nil, "not without the player's say-so")
        #expect(state.zone(of: divination) == .hand)
        let forcedPlay = state.play(divination, force: true)
        let forced = try #require(forcedPlay)
        #expect(forced.zone == .graveyard && forced.tapped == 0)
        #expect(state.spellsCast == 2)
        #expect(state.battlefield.count == 1)
        #expect(state.total == 60)
    }

    @Test func permanentsResolveOntoTheirRows() throws {
        let extra: [(CardItem, Int)] = [
            (try Self.card("Sol Ring", "Artifact", cost: "{1}", text: "{T}: Add {C}{C}."), 1),
            (try Self.card("Pacifism", "Enchantment — Aura", cost: "{1}{W}"), 1),
            (try Self.card("Chandra", "Legendary Planeswalker — Chandra", cost: "{2}{R}{R}", loyalty: "4"), 1),
            (try Self.card("Steel Overseer", "Artifact Creature — Construct", cost: "{2}", power: "1", toughness: "1"), 1),
            (try Self.card("Dryad Arbor", "Land Creature — Forest Dryad", cost: "", power: "1", toughness: "1"), 1),
            (try Self.card("Invasion of Tarkir", "Battle — Siege", cost: "{1}{R}"), 1),
        ]
        var state = Self.game(try Self.standardDeck(extra: extra))
        func put(_ name: String) throws -> PlaytestCard {
            let id = try Self.inHand(&state, name)
            let play: PlaytestPlay = state.card(id)?.info.front.isLand == true ? .front : .free
            let played = state.play(id, as: play)
            #expect(played != nil, "\(name)")
            return try #require(state.card(id))
        }
        let bears = try put("Grizzly Bears")
        #expect(bears.tableRow == .creatures)
        let overseer = try put("Steel Overseer")
        #expect(overseer.tableRow == .creatures, "an artifact creature fights")
        let ring = try put("Sol Ring")
        #expect(ring.tableRow == .permanents)
        let pacifism = try put("Pacifism")
        #expect(pacifism.tableRow == .permanents)
        let battle = try put("Invasion of Tarkir")
        #expect(battle.tableRow == .permanents)
        let chandra = try put("Chandra")
        #expect(chandra.tableRow == .permanents && chandra.counters[.loyalty] == 4, "a planeswalker enters with its loyalty")
        let arbor = try put("Dryad Arbor")
        #expect(arbor.tableRow == .lands && state.landsPlayed == 1, "a land creature is played as a land")
        #expect(state.attackCandidates.contains { $0.id == arbor.id })
        let shockInHand = try Self.inHand(&state, "Shock")
        #expect(state.issue(playing: shockInHand, as: .free) == .notAPermanent)
    }

    @Test func oneLandDropATurn() throws {
        var state = Self.game(try Self.standardDeck())
        let first = try Self.inHand(&state, "Forest")
        let firstLand = state.play(first)
        #expect(firstLand?.isLand == true)
        #expect(state.landsPlayed == 1 && state.spellsCast == 0, "a land is played, not cast")
        let second = try Self.inHand(&state, "Island")
        #expect(state.issue(playing: second) == .landAlreadyPlayed)
        let secondLand = state.play(second)
        #expect(secondLand == nil)
        let extraLand = state.play(second, force: true)
        #expect(extraLand != nil, "an effect may allow more")
        #expect(state.landsPlayed == 2)
        state.toggleTap(first)
        Self.passTurn(&state)
        #expect(state.turn == 2 && state.landsPlayed == 0)
        #expect(state.card(first)?.isTapped == false, "untapped in the untap step")
    }

    @Test func spellsArePaidFromTheNarrowestSources() throws {
        let tundra = try Self.card("Tundra", "Land — Plains Island")
        let charm = try Self.card("Selesnya Charm", "Instant", cost: "{G}{W}")
        var state = Self.game(try Self.standardDeck(extra: [(tundra, 1), (charm, 1), (try Self.plains(), 1)]))
        let forest = try Self.onBattlefield(&state, "Forest")
        let island = try Self.onBattlefield(&state, "Island")
        let dual = try Self.onBattlefield(&state, "Tundra")
        let charmCast = state.play(try Self.inHand(&state, "Selesnya Charm"))
        let paid = try #require(charmCast)
        #expect(paid.tapped == 2)
        #expect(state.card(forest)?.isTapped == true && state.card(dual)?.isTapped == true)
        #expect(state.card(island)?.isTapped == false, "the Island stays up for blue")
        #expect(state.manaAvailable == 1 && state.manaTotal == 3)
    }

    @Test func thePayerMatchesPipsExactly() {
        func source(_ mask: UInt8, _ units: Int = 1, rank: Int = 0) -> PlaytestPaySource {
            PlaytestPaySource(id: UUID(), mana: PlaytestManaSource(mask: mask, units: units), rank: rank)
        }
        let w = PlaytestManaSource.bit(.white), u = PlaytestManaSource.bit(.blue), g = PlaytestManaSource.bit(.green)
        let forest = source(g), island = source(u), tundra = source(w | u)
        let solRing = source(PlaytestManaSource.colorless, 2, rank: 1)

        // {W}{U} from Tundra + Island: Tundra must take the white.
        let wu = PlaytestPayer.pay(PlaytestCost("{W}{U}"), from: [tundra, island])
        #expect(Set(wu?.tapped ?? []) == [tundra.id, island.id])
        #expect(PlaytestPayer.pay(PlaytestCost("{W}{W}"), from: [tundra, island]) == nil)
        // Generic from the Sol Ring's two, then the Forest for green.
        let ring = PlaytestPayer.pay(PlaytestCost("{2}{G}"), from: [forest, solRing, island])
        #expect(Set(ring?.tapped ?? []) == [forest.id, solRing.id], "the ring's second mana is free once it's tapped")
        // {C} needs colourless mana; coloured won't do.
        #expect(PlaytestPayer.pay(PlaytestCost("{C}"), from: [forest]) == nil)
        #expect(PlaytestPayer.pay(PlaytestCost("{C}"), from: [forest, solRing])?.tapped == [solRing.id])
        // Hybrid takes either colour.
        #expect(PlaytestPayer.pay(PlaytestCost("{G/U}{G/U}"), from: [forest, island]) != nil)
        // Phyrexian falls back to life, twobrid to two generic.
        #expect(PlaytestPayer.pay(PlaytestCost("{W/P}"), from: [forest]) == PlaytestPayment(tapped: [], lifePaid: 2))
        #expect(PlaytestPayer.pay(PlaytestCost("{W/P}"), from: [tundra])?.lifePaid == 0)
        #expect(Set(PlaytestPayer.pay(PlaytestCost("{2/W}"), from: [forest, island])?.tapped ?? []) == [forest.id, island.id])
        // X is zero; a free spell taps nothing.
        let x = PlaytestCost("{X}{R}")
        #expect(x.hasX && x.manaValue == 1)
        #expect(PlaytestPayer.pay(PlaytestCost(""), from: [])?.tapped == [])
        let parsed = PlaytestCost("{2}{G/U}{W/P}{2/R}{C}{S}", tax: 4)
        #expect(parsed.pips == [g | u, PlaytestManaSource.colorless])
        #expect(parsed.phyrexian == [w] && parsed.twobrid == [PlaytestManaSource.bit(.red)])
        #expect(parsed.generic == 7 && parsed.text == "{2}{G/U}{W/P}{2/R}{C}{S} + {4}")
    }

    @Test func readingWhatACardTapsFor() {
        func mana(_ type: String, _ text: String) -> PlaytestManaSource? {
            PlaytestReading.manaSource(typeLine: type, text: text, name: "Card")
        }
        let any = PlaytestManaSource.anyColor
        #expect(mana("Basic Land — Forest", "({T}: Add {G}.)") == PlaytestManaSource(mask: PlaytestManaSource.bit(.green), units: 1))
        #expect(mana("Land — Forest Island", "") == PlaytestManaSource(mask: PlaytestManaSource.bit(.green) | PlaytestManaSource.bit(.blue), units: 1))
        #expect(mana("Artifact", "{T}: Add {C}{C}.") == PlaytestManaSource(mask: PlaytestManaSource.colorless, units: 2))
        #expect(mana("Land", "{T}: Add one mana of any color in your commander's color identity.")?.mask == any)
        #expect(mana("Creature — Elf Druid", "{T}: Add {G}.")?.units == 1)
        let pain = mana("Land", "{T}: Add {C}.\n{T}: Add {R} or {G}. Karplusan Forest deals 1 damage to you.")
        #expect(pain?.units == 1 && pain?.mask == PlaytestManaSource.colorless | PlaytestManaSource.bit(.red) | PlaytestManaSource.bit(.green))
        #expect(mana("Artifact", "{1}, {T}: Add {W}{U}.") == nil, "a Signet's {1} is the player's to pay")
        #expect(mana("Artifact — Treasure", "{T}, Sacrifice this token: Add one mana of any color.") == nil)
        #expect(mana("Enchantment", "Creatures you control have \"{T}: Add one mana of any color.\"") == nil, "granted to others")
        #expect(mana("Land", "{T}, Pay 1 life, Sacrifice this land: Search your library for a Forest or Island card.") == nil)
    }

    @Test func readingKeywordsAndEntersTapped() {
        #expect(PlaytestReading.keywords(in: "Flying, haste") == [.flying, .haste])
        #expect(PlaytestReading.keywords(in: "Double strike\nWhenever this creature attacks, draw a card.") == [.doubleStrike])
        #expect(PlaytestReading.keywords(in: "Vigilance, lifelink, ward {2}") == [.vigilance, .lifelink])
        #expect(PlaytestReading.keywords(in: "Creatures you control have haste.").isEmpty, "granted, not its own")
        #expect(PlaytestReading.keywords(in: "Flying, haste, backup 1") == [.flying, .haste], "a keyword the list lacks keeps the rest")
        #expect(PlaytestReading.keywords(in: "Vigilance, enlist\nWhenever this creature attacks, draw a card.") == [.vigilance])
        #expect(PlaytestReading.keywords(in: "Flying, ward—Pay 3 life.") == [.flying], "a known keyword line with a cost")
        #expect(PlaytestReading.keywords(in: "Equipped creature gets +1/+1 and has haste.").isEmpty, "a sentence grants, it isn't a keyword line")
        #expect(PlaytestReading.keywords(in: PlaytestReading.stripReminder("Haste (This creature can attack and {T} as soon as it comes under your control.)")) == [.haste])
        #expect(PlaytestReading.entersTapped(text: "This land enters tapped.\n{T}: Add {B} or {R}.", name: "Sanguine Morass"))
        #expect(PlaytestReading.entersTapped(text: "Selesnya Guildgate enters the battlefield tapped.", name: "Selesnya Guildgate"))
        #expect(!PlaytestReading.entersTapped(text: "This land enters tapped unless you control two or fewer other lands.", name: "Blooming Marsh"))
        #expect(!PlaytestReading.entersTapped(text: "As this land enters, you may pay 2 life. If you don't, it enters tapped.", name: "Breeding Pool"))
        #expect(!PlaytestReading.entersTapped(text: "Creatures your opponents control enter tapped.", name: "Authority of the Consuls"))
    }

    @Test func aLandThatEntersTappedMakesNoManaThatTurn() throws {
        let gate = try Self.card("Selesnya Guildgate", "Land — Gate", text: "This land enters tapped.\n{T}: Add {G} or {W}.")
        var state = Self.game(try Self.standardDeck(extra: [(gate, 1)]))
        let id = try Self.inHand(&state, "Selesnya Guildgate")
        let gatePlayed = state.play(id)
        #expect(gatePlayed != nil)
        #expect(state.card(id)?.isTapped == true)
        #expect(state.manaAvailable == 0 && state.manaTotal == 1)
    }

    @Test func summoningSicknessHoldsBackAttacksAndManaUntilTheNextTurn() throws {
        let elves = try Self.card("Llanowar Elves", "Creature — Elf Druid", cost: "{G}", text: "{T}: Add {G}.", power: "1", toughness: "1")
        let goblin = try Self.card("Raging Goblin", "Creature — Goblin Berserker", cost: "{R}", text: "Haste", power: "1", toughness: "1")
        var state = Self.game(try Self.standardDeck(extra: [(elves, 1), (goblin, 1)]))
        try Self.onBattlefield(&state, "Forest")
        try Self.onBattlefield(&state, "Mountain")
        let elf = try Self.inHand(&state, "Llanowar Elves")
        let elfCast = state.play(elf)
        #expect(elfCast?.tapped == 1)
        let card = try #require(state.card(elf))
        #expect(card.isSummoningSick(on: state.turn))
        #expect(!state.paySources().contains { $0.id == elf }, "a sick elf can't tap for mana")
        #expect(!state.canAttack(card))
        let hasty = try Self.inHand(&state, "Raging Goblin")
        let goblinCast = state.play(hasty)
        #expect(goblinCast != nil)
        #expect(state.canAttack(try #require(state.card(hasty))), "haste")
        #expect(state.manaTotal == 2, "a sick elf isn't counted in the total either")
        Self.passTurn(&state)
        #expect(state.canAttack(try #require(state.card(elf))))
        #expect(state.manaAvailable == 3 && state.manaTotal == 3, "Forest, Mountain and the elf")
    }

    @Test func commanderTaxIsTwoMorePerCastFromTheCommandZone() throws {
        let captain = try Self.card("Captain", "Legendary Creature — Human Soldier", cost: "{2}{W}", power: "3", toughness: "3")
        var state = Self.game(Self.deck([(try Self.plains(), 40), (try Self.shock(), 59)], commanders: [captain], format: .commander))
        for _ in 0..<7 { try Self.onBattlefield(&state, "Plains") }
        let id = state.command[0].id
        #expect(state.cost(of: id, as: .front)?.manaValue == 3)
        let firstCast = state.play(id)
        #expect(firstCast?.tapped == 3)
        #expect(state.zone(of: id) == .battlefield)
        let returned = state.move(id, to: .command)
        #expect(returned)
        let taxed = try #require(state.cost(of: id, as: .front))
        #expect(taxed.manaValue == 5 && taxed.text == "{2}{W} + {2}")
        state.untapAll()
        let secondCast = state.play(id)
        #expect(secondCast?.tapped == 5)
        #expect(state.commanderCasts[id] == 2)
        let shockToCommand = state.move(try Self.inHand(&state, "Shock"), to: .command)
        #expect(shockToCommand == false, "only a commander goes to the command zone")
    }

    @Test func anOathbreakersSignatureSpellGoesBackToTheCommandZone() throws {
        let walker = try Self.card("Chandra", "Legendary Planeswalker — Chandra", cost: "{2}{R}{R}", loyalty: "4")
        let signature = try Self.card("Fiery Signature", "Instant", cost: "{R}", text: "Deal 3 damage.")
        var state = Self.game(Self.deck([(try Self.mountain(), 58)], commanders: [walker, signature], format: .oathbreaker))
        try Self.onBattlefield(&state, "Mountain")
        let spell = try #require(state.command.first { $0.card.name == "Fiery Signature" })
        let signatureCast = state.play(spell.id)
        #expect(signatureCast?.zone == .command)
        #expect(state.zone(of: spell.id) == .command && state.commanderCasts[spell.id] == 1)
    }

    @Test func flashbackAdventuresAndOmensGoWhereTheirRulesSay() throws {
        let scavenger = try Self.faces([("Hollow Scavenger", "Creature — Wolf", "{2}{G}", "{1}, Sacrifice a Food: This creature gets +2/+2."),
                                        ("Bakery Raid", "Sorcery — Adventure", "{G}", "Create a Food token.")],
                                       doubleFaced: false, cost: "{2}{G} // {G}", power: "3", toughness: "2")
        let regent = try Self.faces([("Scavenger Regent", "Creature — Dragon", "{3}{B}", "Flying"),
                                     ("Exude Toxin", "Sorcery — Omen", "{X}{B}{B}", "Each non-Dragon creature gets -X/-X.")],
                                    doubleFaced: false, cost: "{3}{B} // {X}{B}{B}", power: "4", toughness: "4")
        var state = Self.game(try Self.standardDeck(extra: [(scavenger, 1), (regent, 1)]))

        // Flashback: cast from the graveyard, exiled.
        let shock = try Self.inHand(&state, "Shock")
        let binned = state.move(shock, to: .graveyard)
        #expect(binned)
        #expect(state.playOptions(shock) == [.front])
        let flashback = state.play(shock, force: true)
        #expect(flashback?.zone == .exile)

        // Adventure: the sorcery half to exile, then the creature from there.
        let card = try Self.inHand(&state, "Hollow Scavenger // Bakery Raid")
        #expect(state.card(card)?.info.layout == .adventure)
        #expect(state.playOptions(card) == [.front, .back, .free])
        #expect(state.cost(of: card, as: .back)?.text == "{G}")
        let raidPlay = state.play(card, as: .back, force: true)
        let raid = try #require(raidPlay)
        #expect(raid.zone == .exile && raid.name == "Bakery Raid")
        #expect(state.card(card)?.onAdventure == true)
        #expect(state.playOptions(card) == [.front], "only the creature may be cast from the adventure")
        let creatureCast = state.play(card, force: true)
        #expect(creatureCast?.zone == .battlefield)
        #expect(state.card(card)?.onAdventure == false && state.card(card)?.power == 3)

        // Omen: shuffled back into the library.
        let omen = try Self.inHand(&state, "Scavenger Regent // Exude Toxin")
        let library = state.librarySize
        var rng = SeededGenerator(seed: 4)
        let omenCast = state.play(omen, as: .back, force: true, using: &rng)
        #expect(omenCast?.zone == .library)
        #expect(state.zone(of: omen) == .library && state.librarySize == library + 1)
        #expect(state.total == 62)
    }

    @Test func aModalDoubleFacedCardIsPlayedAsEitherFace() throws {
        let insight = try Self.faces([("Bloodsoaked Insight", "Sorcery", "{5}{B/R}{B/R}", "Draw two cards."),
                                      ("Sanguine Morass", "Land", "", "This land enters tapped.\n{T}: Add {B} or {R}.")],
                                     doubleFaced: true)
        var state = Self.game(try Self.standardDeck(extra: [(insight, 2)]))
        let land = try Self.inHand(&state, "Bloodsoaked Insight // Sanguine Morass")
        let info = try #require(state.card(land)?.info)
        #expect(info.layout == .modal && info.backIsPlayable)
        #expect(info.front.cost == "{5}{B/R}{B/R}" && info.back?.cost == nil, "the back's cost lives on its face")
        let landPlay = state.play(land, as: .back)
        let played = try #require(landPlay)
        #expect(played.isLand && played.name == "Sanguine Morass")
        let morass = try #require(state.card(land))
        #expect(morass.showsBack && morass.tableRow == .lands && morass.isTapped, "enters tapped, its back's text")
        #expect(morass.face.mana?.mask == PlaytestManaSource.bit(.black) | PlaytestManaSource.bit(.red))
        #expect(morass.imageURL == "https://img/Sanguine Morass")
        #expect(state.landsPlayed == 1)

        let spell = try #require((state.hand + state.library).first { $0.card.name == "Bloodsoaked Insight // Sanguine Morass" }).id
        let putDown = state.move(spell, to: .battlefield)
        #expect(putDown == false, "a modal card enters front up, and a sorcery can't")
        if state.zone(of: spell) != .hand {
            let inHand = state.move(spell, to: .hand)
            #expect(inHand)
        }
        let spellCast = state.play(spell, force: true)
        #expect(spellCast?.zone == .graveyard)
    }

    @Test func aTransformingCardIsCastFrontUpAndTurnsOver() throws {
        let ajani = try Self.faces([("Ajani, Nacatl Pariah", "Legendary Creature — Cat Warrior", "{1}{W}",
                                     "When Ajani enters, create a 2/1 white Cat Warrior creature token.\nWhen one or more other Cats you control die, you may exile Ajani, then return him to the battlefield transformed under his owner's control."),
                                    ("Ajani, Nacatl Avenger", "Legendary Planeswalker — Ajani", "", "+2: Put a +1/+1 counter on each Cat you control.")],
                                   doubleFaced: true)
        let fragment = try Self.faces([("Cryptolith Fragment", "Artifact", "{3}", "This artifact enters tapped.\n{T}: Add one mana of any color. Each player loses 1 life.\nAt the beginning of your upkeep, if each player has 10 or less life, transform this artifact."),
                                       ("Aurora of Emrakul", "Creature — Eldrazi Reflection", "", "Flying, deathtouch")],
                                      doubleFaced: true)
        var state = Self.game(try Self.standardDeck(extra: [(ajani, 1), (fragment, 1)]))
        let id = try Self.inHand(&state, "Ajani, Nacatl Pariah // Ajani, Nacatl Avenger")
        let info = try #require(state.card(id)?.info)
        #expect(info.layout == .transform && !info.backIsPlayable && info.transforms)
        #expect(state.playOptions(id) == [.front, .free], "the back of a transforming card is never cast")
        let ajaniPut = state.play(id, as: .free)
        #expect(ajaniPut != nil)
        #expect(state.card(id)?.tableRow == .creatures)
        state.transform(id)
        let turned = try #require(state.card(id))
        #expect(turned.showsBack && turned.name == "Ajani, Nacatl Avenger" && turned.tableRow == .permanents)

        let artifact = try Self.inHand(&state, "Cryptolith Fragment // Aurora of Emrakul")
        let fragmentPut = state.play(artifact, as: .free)
        #expect(fragmentPut != nil)
        let card = try #require(state.card(artifact))
        #expect(card.isTapped && card.face.mana?.mask == PlaytestManaSource.anyColor)
    }

    /// Craft, disturb and meld turn a card over without the word
    /// "transform" once the reminder text is gone; read as modal, the
    /// inspector offered to cast the back from hand.
    @Test func craftAndDisturbCardsTransformAndDisturbIsCastFromTheGraveyard() throws {
        let beggar = try Self.faces([("Beloved Beggar", "Creature — Human Peasant", "{1}{W}", "Disturb {4}{W}{W}"),
                                     ("Generous Soul", "Enchantment Creature — Spirit", "", "Flying, vigilance\nIf Generous Soul would be put into a graveyard from anywhere, exile it instead.")],
                                    doubleFaced: true)
        let throne = try Self.faces([("Throne of the Grim Captain", "Legendary Artifact", "{4}", "{T}: Mill two cards.\nCraft with a Dinosaur, a Merfolk, a Pirate, and a Vampire {4}"),
                                     ("The Grim Captain", "Legendary Creature — Skeleton Spirit Pirate", "", "Menace\nWhenever The Grim Captain attacks, each opponent sacrifices a nonland permanent.")],
                                    doubleFaced: true)
        var state = Self.game(try Self.standardDeck(extra: [(beggar, 1), (throne, 1)]))

        let craft = try Self.inHand(&state, "Throne of the Grim Captain // The Grim Captain")
        #expect(state.card(craft)?.info.layout == .transform)
        #expect(state.card(craft)?.info.disturbCost == nil)
        #expect(state.playOptions(craft) == [.front, .free], "the crafted back is never cast")

        let id = try Self.inHand(&state, "Beloved Beggar // Generous Soul")
        let info = try #require(state.card(id)?.info)
        #expect(info.layout == .transform && !info.backIsPlayable && info.transforms)
        #expect(info.disturbCost == "{4}{W}{W}")
        #expect(state.playOptions(id) == [.front, .free], "disturb is never cast from hand")
        #expect(!state.options(for: id).contains { $0.title.contains("Generous Soul") })

        let binned = state.move(id, to: .graveyard)
        #expect(binned)
        #expect(state.playOptions(id) == [.front, .back], "from the graveyard, transformed")
        #expect(state.cost(of: id, as: .back)?.text == "{4}{W}{W}", "the disturb cost, not the back's (none)")
        #expect(state.cost(of: id, as: .back)?.isKnown == true)
        let disturb = try #require(state.options(for: id).first { $0.command == .play(.back, force: true) })
        #expect(disturb.title == "Cast Generous Soul (Disturb)")
        let cast = state.play(id, as: .back, force: true)
        #expect(cast?.zone == .battlefield && cast?.name == "Generous Soul")
        let soul = try #require(state.card(id))
        #expect(soul.showsBack && soul.name == "Generous Soul" && soul.face.keywords.contains(.flying))
        #expect(state.total == 62)
    }

    @Test func aDragPlaysTheFaceThatNeedsNoSaySo() throws {
        let insight = try Self.faces([("Bloodsoaked Insight", "Sorcery", "{5}{B/R}{B/R}", "Draw two cards."),
                                      ("Sanguine Morass", "Land", "", "This land enters tapped.\n{T}: Add {B} or {R}.")],
                                     doubleFaced: true)
        let scavenger = try Self.faces([("Hollow Scavenger", "Creature — Wolf", "{2}{G}", ""),
                                        ("Bakery Raid", "Sorcery — Adventure", "{G}", "Create a Food token.")],
                                       doubleFaced: false, cost: "{2}{G} // {G}", power: "3", toughness: "2")
        var state = Self.game(try Self.standardDeck(extra: [(insight, 1), (scavenger, 1)]))
        let mdfc = try Self.inHand(&state, "Bloodsoaked Insight // Sanguine Morass")
        #expect(state.dragPlay(mdfc) == .back, "the land, while the land drop is ready and the spell can't be paid")
        let forest = try Self.inHand(&state, "Forest")
        state.play(forest)
        #expect(state.dragPlay(mdfc) == .front, "once a land is played, the front — which then asks")
        let adventure = try Self.inHand(&state, "Hollow Scavenger // Bakery Raid")
        #expect(state.issue(playing: adventure, as: .back) == nil, "the Forest pays for the adventure")
        #expect(state.dragPlay(adventure) == .front, "an adventure is cast from the sheet, never by a drag")
    }

    @Test func playOrDrawIsAChoiceUndoKeeps() throws {
        var state = PlaytestState(snapshot: try Self.standardDeck())
        var rng = SeededGenerator(seed: 6)
        state.newGame(using: &rng)
        var history = PlaytestHistory()
        history.record(state)
        state.mulligan(using: &rng)
        history.amend { $0.setOnThePlay(false) }
        state.setOnThePlay(false)
        let back = history.undo(from: state)
        let undone = try #require(back)
        #expect(undone.mulligans == 0 && !undone.onThePlay, "the mulligan is undone, the choice stays")
        let forward = history.redo(from: undone)
        #expect(forward?.onThePlay == false)
    }

    @Test @MainActor func cardsDecodeAtSharedSizesAndThePreviewFitsTheTable() {
        let aspect = 488.0 / 680.0
        // Longest edge, in points: the hand's 100pt card is 139pt tall.
        #expect(PlaytestCardView.decodeEdge(for: 64, aspect: aspect) == 160)
        #expect(PlaytestCardView.decodeEdge(for: 100, aspect: aspect) == 160, "the table and the hand share a decode")
        #expect(PlaytestCardView.decodeEdge(for: 44, aspect: aspect) == 160)
        #expect(PlaytestCardView.decodeEdge(for: 250, aspect: aspect) == 352, "the preview and the sheet share another")
        #expect(PlaytestCardView.decodeEdge(for: 150, aspect: aspect) == 224)
        #expect(PlaytestCardView.decodeEdge(for: 600, aspect: aspect) == 848)
        #expect(PlaytestHand.previewWidth(cardWidth: 100, maxHeight: .infinity) == 250)
        let short = PlaytestHand.previewWidth(cardWidth: 100, maxHeight: 240)
        #expect(short / CGFloat(aspect) <= 220.5 && short >= 100, "no taller than the room above the hand")
        #expect(PlaytestHand.visibleHeight(cardWidth: 100) == 118)
    }

    @Test @MainActor func theInspectorEstimatesItsHeightFromWhatItOffers() throws {
        var state = Self.game(try Self.standardDeck())
        let shock = try Self.inHand(&state, "Shock")
        let inHand = PlaytestInspector.estimatedHeight(options: state.options(for: shock), counters: 0, cardWidth: 200)
        let bears = try Self.onBattlefield(&state, "Grizzly Bears")
        let onTable = PlaytestInspector.estimatedHeight(options: state.options(for: bears), counters: 3, cardWidth: 200)
        let bare = PlaytestInspector.estimatedHeight(options: [], counters: 0, cardWidth: 200)
        #expect(bare > 200 / (488.0 / 680.0), "at least the card")
        #expect(inHand > bare && onTable > inHand, "taller with more to offer")
        #expect(onTable < 1000)
    }

    @Test func aSplitCardCastsEitherHalfAndARoomIsAPermanent() throws {
        let ready = try Self.faces([("Ready", "Instant", "{1}{G}{W}", "Creatures you control gain indestructible."),
                                    ("Willing", "Instant", "{1}{W}{B}", "Creatures you control gain deathtouch and lifelink.")],
                                   doubleFaced: false, cost: "{1}{G}{W} // {1}{W}{B}")
        let room = try Self.faces([("Unholy Annex", "Enchantment — Room", "{2}{B}", "At the beginning of your end step, draw a card."),
                                   ("Ritual Chamber", "Enchantment — Room", "{3}{B}{B}", "When you unlock this door, create a 6/6 Demon.")],
                                  doubleFaced: false, cost: "{2}{B} // {3}{B}{B}")
        var state = Self.game(try Self.standardDeck(extra: [(ready, 1), (room, 1)]))
        let split = try Self.inHand(&state, "Ready // Willing")
        #expect(state.card(split)?.info.layout == .split)
        #expect(state.cost(of: split, as: .back)?.text == "{1}{W}{B}")
        let willingCast = state.play(split, as: .back, force: true)
        let willing = try #require(willingCast)
        #expect(willing.name == "Willing" && willing.zone == .graveyard)
        let annex = try Self.inHand(&state, "Unholy Annex // Ritual Chamber")
        let annexCast = state.play(annex, force: true)
        #expect(annexCast?.zone == .battlefield)
        #expect(state.card(annex)?.tableRow == .permanents)
    }

    // MARK: The battlefield

    @Test func tokensPileUpAndCeaseToExistWhenTheyLeave() throws {
        var state = Self.game(try Self.standardDeck())
        let treasure = try #require(PlaytestTokenTemplate.common.first { $0.name == "Treasure" })
        state.createTokens(treasure, count: 3)
        #expect(state.tokenCount == 3)
        let piles = state.stacks(in: .permanents)
        #expect(piles.count == 1 && piles[0].count == 3, "three alike make one pile")
        #expect(state.paySources().isEmpty, "a Treasure's sacrifice is the player's call")
        state.toggleTap(piles[0].actionCard.id)
        #expect(state.stacks(in: .permanents).map(\.count) == [2, 1], "the tapped one leaves the pile")
        let graveyard = state.graveyard.count
        let sacrificed = state.move(piles[0].actionCard.id, to: .graveyard)
        #expect(sacrificed)
        #expect(state.tokenCount == 2 && state.graveyard.count == graveyard, "a token in the graveyard ceases to exist")
        let bounced = state.move(piles[0].top.id, to: .hand)
        #expect(bounced)
        #expect(state.tokenCount == 1 && state.hand.allSatisfy { !$0.isToken })

        state.createTokens(.custom(name: "Zombie", power: 2, toughness: 2), count: 1)
        let zombie = try #require(state.battlefield.first { $0.name == "Zombie" })
        #expect(zombie.tableRow == .creatures && zombie.power == 2 && zombie.isSummoningSick(on: state.turn))
        let bears = try Self.onBattlefield(&state, "Grizzly Bears")
        state.createTokenCopy(of: bears)
        #expect(state.battlefield.filter { $0.card.name == "Grizzly Bears" }.map(\.isToken) == [false, true])
        #expect(state.total == 60, "tokens are not cards of the deck")

        let soldier = PlaytestTokenTemplate(DeckToken(id: "Soldier|Token Creature — Soldier", name: "Soldier",
                                                      typeLine: "Token Creature — Soldier", imageURL: nil, artCropURL: nil,
                                                      makers: ["Raise the Alarm"], power: "1", toughness: "1"))
        #expect(soldier.subtitle == "Creature — Soldier · 1/1")
        #expect(CardItem(token: soldier).typeLine == "Token Creature — Soldier")
    }

    @Test func countersCancelAndKill() throws {
        let walker = try Self.card("Chandra", "Legendary Planeswalker — Chandra", cost: "{2}{R}{R}", loyalty: "3")
        var state = Self.game(try Self.standardDeck(extra: [(walker, 1)]))
        let bears = try Self.onBattlefield(&state, "Grizzly Bears")
        state.addCounters(.plusOne, 2, to: bears)
        #expect(state.card(bears)?.power == 4 && state.card(bears)?.toughness == 4)
        state.addCounters(.minusOne, 1, to: bears)
        #expect(state.card(bears)?.counters == [.plusOne: 1], "+1/+1 and −1/−1 cancel")
        state.addCounters(.minusOne, 3, to: bears)
        #expect(state.zone(of: bears) == .graveyard, "0 toughness dies")
        #expect(state.card(bears)?.counters.isEmpty == true)
        let chandra = try Self.onBattlefield(&state, "Chandra")
        #expect(state.card(chandra)?.counters[.loyalty] == 3)
        state.addCounters(.loyalty, -3, to: chandra)
        #expect(state.zone(of: chandra) == .graveyard, "no loyalty")
        state.createTokens(.custom(name: "Spirit", power: 1, toughness: 1))
        let spirit = try #require(state.battlefield.first { $0.isToken }).id
        state.addCounters(.minusOne, 1, to: spirit)
        #expect(state.card(spirit) == nil && state.tokenCount == 0)
        #expect(state.total == 61)
    }

    @Test func attackingTapsAndDealsDamage() throws {
        let knight = try Self.card("Knight", "Creature — Human Knight", cost: "{2}{W}", text: "Double strike, lifelink", power: "2", toughness: "2")
        let angel = try Self.card("Serra Angel", "Creature — Angel", cost: "{3}{W}{W}", text: "Flying, vigilance", power: "4", toughness: "4")
        let wall = try Self.card("Wall", "Creature — Wall", cost: "{1}", text: "Defender", power: "0", toughness: "4")
        var state = Self.game(try Self.standardDeck(extra: [(knight, 1), (angel, 1), (wall, 1)]))
        let k = try Self.onBattlefield(&state, "Knight")
        let a = try Self.onBattlefield(&state, "Serra Angel")
        let b = try Self.onBattlefield(&state, "Grizzly Bears")
        try Self.onBattlefield(&state, "Wall")
        #expect(state.attackCandidates.count == 3, "a defender can't attack")
        #expect(!state.canAttack(try #require(state.card(k))), "summoning sick")
        Self.passTurn(&state)
        let attack = state.attack(with: [k, a, b])
        let result = try #require(attack)
        #expect(result.attackers == 3 && result.damage == 4 + 4 + 2 && result.lifeGained == 4)
        #expect(state.opponentLife == 10 && state.life == 24)
        #expect(state.card(k)?.isTapped == true && state.card(b)?.isTapped == true)
        #expect(state.card(a)?.isTapped == false, "vigilance")
        let again = state.attack(with: [k])
        #expect(again == nil, "a tapped creature can't attack")
        #expect(state.defeatedOnTurn == nil)
        state.adjustOpponentLife(-10)
        #expect(state.defeatedOnTurn == state.turn)
        state.adjustOpponentLife(5)
        #expect(state.defeatedOnTurn == nil, "back above zero")
    }

    @Test func twentyOneCommanderDamageDefeatsTheOpponent() throws {
        let captain = try Self.card("Captain", "Legendary Creature — Human", cost: "{2}{W}", power: "7", toughness: "7")
        var state = Self.game(Self.deck([(try Self.plains(), 40), (try Self.shock(), 59)], commanders: [captain], format: .commander))
        let id = state.command[0].id
        let putDown = state.move(id, to: .battlefield)
        #expect(putDown)
        for _ in 0..<3 {
            Self.passTurn(&state)
            let swing = state.attack(with: [id])
            #expect(swing?.damage == 7)
        }
        #expect(state.commanderDamage[id] == 21 && state.opponentLife == 19)
        #expect(state.defeatedOnTurn == state.turn, "21 from one commander")
    }

    @Test func cleanupDiscardsDownToSeven() throws {
        let tower = try Self.card("Reliquary Tower", "Land", text: "You have no maximum hand size.\n{T}: Add {C}.")
        var state = Self.game(try Self.standardDeck(extra: [(tower, 1)]))
        state.draw(2)
        #expect(state.hand.count == 9)
        state.endTurn()
        #expect(state.phase == .cleanup(2) && state.turn == 1)
        state.discard(state.hand[0].id)
        #expect(state.phase == .cleanup(1))
        state.discard(state.hand[0].id)
        #expect(state.phase == .main && state.turn == 2)
        #expect(state.hand.count == 8 && state.graveyard.count == 2)

        try Self.onBattlefield(&state, "Reliquary Tower")
        state.draw(3)
        state.endTurn()
        #expect(state.phase == .main && state.turn == 3, "no maximum hand size")
    }

    // MARK: The library

    @Test func scrySurveilLookAndSearch() throws {
        var state = Self.game(try Self.standardDeck())
        let top = state.top(3).map(\.id)
        state.arrangeTop([(top[2], .top), (top[0], .bottom), (top[1], .top)], as: .scry)
        #expect(Array(state.library.prefix(2).map(\.id)) == [top[2], top[1]])
        #expect(state.library.last?.id == top[0])
        let next = state.library[0].id
        state.arrangeTop([(next, .hand)], as: .scry)
        #expect(state.library[0].id == next, "a scry can't put a card in hand")
        state.arrangeTop([(next, .graveyard)], as: .surveil)
        #expect(state.zone(of: next) == .graveyard)
        let milled = state.mill(2)
        #expect(milled == 2 && state.graveyard.count == 3)

        let forest = try #require(state.library.first { $0.card.name == "Forest" }).id
        var rng = SeededGenerator(seed: 9)
        let fetched = state.search(take: forest, to: .battlefieldTapped, using: &rng)
        #expect(fetched)
        #expect(state.card(forest)?.isTapped == true && state.zone(of: forest) == .battlefield)
        let shock = try #require(state.library.first { $0.card.name == "Shock" }).id
        let onto = state.search(take: shock, to: .battlefield, using: &rng)
        #expect(!onto, "an instant can't be put onto the battlefield")
        let tutored = state.search(take: shock, to: .top, using: &rng)
        #expect(tutored)
        #expect(state.library[0].id == shock, "on top after the shuffle")
        #expect(state.total == 60)
    }

    @Test func drawStopsAtAnEmptyLibrary() throws {
        var state = PlaytestState(snapshot: Self.deck([(try Self.forest(), 2), (try Self.shock(), 1)]))
        let drawn = state.draw(5)
        #expect(drawn == 3)
        let nothing = state.draw()
        #expect(nothing == 0)
        #expect(state.log.last?.isNotable == true)
        #expect(state.hand.count == 3 && state.librarySize == 0)
    }

    // MARK: The game

    @Test func undoAndRedoWalkWholeStates() throws {
        var state = Self.game(try Self.standardDeck())
        var history = PlaytestHistory()
        let start = state
        history.record(state)
        state.draw()
        let drawn = state
        history.record(state)
        state.endTurn()
        #expect(history.canUndo && !history.canRedo)
        let back = history.undo(from: state)
        state = try #require(back)
        #expect(state == drawn)
        let backAgain = history.undo(from: state)
        state = try #require(backAgain)
        #expect(state == start)
        #expect(!history.canUndo && history.canRedo)
        let forward = history.redo(from: state)
        state = try #require(forward)
        #expect(state == drawn)
        history.record(state)
        #expect(!history.canRedo, "a new step drops the redo")
    }

    @Test func newGameResetsEverything() throws {
        let captain = try Self.card("Captain", "Legendary Creature — Human", cost: "{2}{W}", power: "3", toughness: "3")
        var state = Self.game(Self.deck([(try Self.plains(), 40), (try Self.shock(), 59)], commanders: [captain], format: .commander))
        let id = state.command[0].id
        state.move(id, to: .battlefield)
        state.createTokens(.custom(name: "Spirit", power: 1, toughness: 1))
        state.adjustLife(-5)
        Self.passTurn(&state)
        state.newGame()
        #expect(state.phase == .opening && state.turn == 0)
        #expect(state.command.map(\.id) == [id] && state.battlefield.isEmpty && state.tokenCount == 0)
        #expect(state.hand.count == 7 && state.life == 40 && state.commanderCasts.isEmpty)
        #expect(state.total == 100)
    }

    // MARK: The inspector's offer

    @Test func theInspectorOffersWhatTheCardCanDoFromWhereItIs() throws {
        let insight = try Self.faces([("Bloodsoaked Insight", "Sorcery", "{5}{B/R}{B/R}", "Draw two cards."),
                                      ("Sanguine Morass", "Land", "", "This land enters tapped.\n{T}: Add {B} or {R}.")],
                                     doubleFaced: true)
        var opening = PlaytestState(snapshot: try Self.standardDeck())
        opening.newGame()
        #expect(opening.options(for: opening.hand[0].id).isEmpty, "nothing is played from the opening hand")

        var state = Self.game(try Self.standardDeck(extra: [(insight, 1)]))
        let shock = try Self.inHand(&state, "Shock")
        let unpaid = try #require(state.options(for: shock).first)
        #expect(unpaid.title == "Cast Shock" && unpaid.isPrimary)
        #expect(unpaid.command == .play(.front, force: true), "choosing it is the say-so")
        #expect(unpaid.caption?.contains("Not enough mana") == true)
        try Self.onBattlefield(&state, "Mountain")
        let cast = try #require(state.options(for: shock).first)
        #expect(cast.command == .play(.front, force: false))
        #expect(cast.caption == "Costs R · Resolves into the graveyard · taps 1", "\(cast.caption ?? "")")
        #expect(!state.options(for: shock).contains { $0.title == "Put onto the Battlefield" }, "an instant is never a permanent")
        #expect(state.options(for: shock).map(\.title).suffix(4) == ["Discard", "Exile", "Top of Library", "Bottom of Library"])
        var rng = SeededGenerator(seed: 3)
        let applied = state.apply(cast.command, to: shock, using: &rng)
        #expect(applied && state.zone(of: shock) == .graveyard)

        state.untapAll()
        let flashback = try #require(state.options(for: shock).first)
        #expect(flashback.title == "Flashback Shock" && flashback.caption?.contains("Exiled after it resolves") == true)
        #expect(state.whereabouts(of: shock) == "In your graveyard")

        let mdfc = try Self.inHand(&state, "Bloodsoaked Insight // Sanguine Morass")
        let titles = state.options(for: mdfc).map(\.title)
        #expect(titles.prefix(2) == ["Cast Bloodsoaked Insight", "Play Sanguine Morass"])
        let land = try #require(state.options(for: mdfc).first { $0.title == "Play Sanguine Morass" })
        #expect(land.caption == "Your land for the turn" && land.command == .play(.back, force: false))
        let playedLand = state.apply(land.command, to: mdfc, using: &rng)
        #expect(playedLand)
        let forest = try Self.inHand(&state, "Forest")
        let extra = try #require(state.options(for: forest).first)
        #expect(extra.command == .play(.front, force: true) && extra.caption?.contains("played a land") == true)

        let untap = try #require(state.options(for: mdfc).first)
        #expect(untap.title == "Untap" && untap.keepsOpen, "it entered tapped")
        #expect(state.whereabouts(of: mdfc) == "On the battlefield · tapped", "enters tapped")
        state.createTokens(.custom(name: "Spirit", power: 1, toughness: 1))
        let spirit = try #require(state.battlefield.first { $0.isToken }).id
        #expect(state.options(for: spirit).first { $0.title == "Destroy / Sacrifice" }?.caption == "A token ceases to exist when it leaves")
        #expect(state.counterKinds(for: spirit) == [.plusOne, .minusOne, .charge])
        #expect(state.whereabouts(of: spirit) == "A token on the battlefield · summoning sick")
    }

    @Test func aCommandersOfferShowsItsTax() throws {
        let captain = try Self.card("Captain", "Legendary Creature — Human", cost: "{2}{W}", power: "3", toughness: "3")
        var state = Self.game(Self.deck([(try Self.plains(), 40), (try Self.shock(), 59)], commanders: [captain], format: .commander))
        for _ in 0..<5 { try Self.onBattlefield(&state, "Plains") }
        let id = state.command[0].id
        #expect(state.hasCommanders)
        var rng = SeededGenerator(seed: 5)
        let first = try #require(state.options(for: id).first)
        #expect(first.title == "Cast Captain" && first.caption == "Costs 2W · Resolves onto the battlefield · taps 3")
        state.apply(first.command, to: id, using: &rng)
        state.move(id, to: .command)
        state.untapAll()
        #expect(state.whereabouts(of: id) == "In the command zone · tax {2}")
        #expect(state.options(for: id).first?.caption == "Costs 2W + 2 · Resolves onto the battlefield · taps 5")
        #expect(state.options(for: id).map(\.title) == ["Cast Captain", "Put onto the Battlefield", "To Hand"])
    }

    // MARK: The fanned hand

    @Test func aQuickReleaseIsATapAndAHoldIsALook() {
        #expect(PlaytestTouchTiming.previewDelay < .milliseconds(150), "the preview comes up almost at once")
        #expect(PlaytestTouchTiming.isTap(held: 0.08, wandered: false))
        #expect(PlaytestTouchTiming.isTap(held: 0.18, wandered: false), "the preview flashed up, but it was still a tap")
        #expect(!PlaytestTouchTiming.isTap(held: 0.4, wandered: false), "a look, not a tap")
        #expect(!PlaytestTouchTiming.isTap(held: 0.08, wandered: true), "a flick is a drag or a scrub")
    }

    @Test func aFingerOnTheFanFindsTheCardWhoseStripShows() {
        for count in 1...12 {
            let layout = PlaytestFanLayout(count: count, width: 402, cardWidth: 100)
            for i in 0..<count {
                let strip = layout.strip(i)
                #expect(layout.index(at: (strip.minX + strip.maxX) / 2) == i, "\(count) cards, card \(i)")
                let slot = layout.slot(i)
                #expect(slot.x - 50 >= 0 && slot.x + 50 <= 402, "\(count) cards fit the width")
            }
            #expect(layout.index(at: -5) == nil)
            if count > 1 {
                #expect(layout.slot(0).angle < 0 && layout.slot(count - 1).angle > 0, "turned out from the middle")
                #expect(layout.slot(0).top > layout.slot(count / 2).top || count == 2, "dipping at the edges")
            }
        }
        #expect(PlaytestFanLayout(count: 2, width: 402, cardWidth: 100).step == 78, "few cards: most of a card apart")
    }

    /// Hundreds of random moves on a seed: every card of the deck is
    /// always somewhere, exactly once, and no instant is ever a permanent.
    @Test func copiesAreConservedThroughARandomGame() throws {
        var state = Self.game(try Self.standardDeck())
        var rng = SeededGenerator(seed: 42)
        for step in 0..<600 {
            let all = PlaytestZone.allCases.flatMap { state.cards(in: $0) }
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: state.draw(Int.random(in: 1...2, using: &rng))
            case 1: if let card = state.hand.randomElement(using: &rng) { state.play(card.id, force: true, using: &rng) }
            case 2: if let card = state.battlefield.randomElement(using: &rng) { state.toggleTap(card.id) }
            case 3: if let card = all.randomElement(using: &rng), let zone = PlaytestZone.allCases.randomElement(using: &rng) {
                state.move(card.id, to: zone, libraryEnd: Bool.random(using: &rng) ? .top : .bottom)
            }
            case 4: Self.passTurn(&state)
            case 5: if let card = state.graveyard.randomElement(using: &rng) { state.play(card.id, force: true, using: &rng) }
            case 6: state.createTokens(.custom(name: "Goblin", power: 1, toughness: 1), count: 2)
            case 7: if let card = state.battlefield.randomElement(using: &rng) { state.addCounters(.minusOne, 1, to: card.id) }
            case 8: if let card = state.library.randomElement(using: &rng) { state.search(take: card.id, to: .hand, using: &rng) }
            default: state.mill(1)
            }
            #expect(state.total == 60, "step \(step)")
            #expect(Set(all.map(\.id)).count == all.count, "step \(step): no card in two places")
            #expect(state.battlefield.allSatisfy { $0.face.isPermanent }, "step \(step): only permanents on the battlefield")
            #expect(PlaytestZone.allCases.filter { $0 != .battlefield }.allSatisfy { zone in state.cards(in: zone).allSatisfy { !$0.isToken } },
                    "step \(step): tokens only on the battlefield")
        }
    }
}
