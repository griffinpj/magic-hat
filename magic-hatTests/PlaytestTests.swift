import Testing
import Foundation
@testable import magic_hat

/// The playtest table: copies conserved through every move, a seeded
/// shuffle repeatable, the London mulligan's bottoming, a turn's untap and
/// draw, and the commander's zone.
@Suite("Playtest")
struct PlaytestTests {
    static func deck(lands: Int = 30, spells: Int = 60, commander: Bool = true) throws -> DeckSnapshot {
        var rows: [DeckCardItem] = []
        if commander {
            rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Captain", type: "Legendary Creature — Human"), board: .commander))
        }
        // Playsets, so copies of one card are distinct instances.
        var landsLeft = lands
        while landsLeft > 0 {
            let n = min(4, landsLeft)
            rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Plains \(landsLeft)", type: "Basic Land — Plains"), qty: n))
            landsLeft -= n
        }
        for i in 0..<spells {
            rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Spell \(i)", type: "Instant")))
        }
        return DeckPlanTests.snapshot(rows)
    }

    @Test func startsWithEveryCopyInTheLibraryAndTheCommanderInCommand() throws {
        let state = PlaytestState(snapshot: try Self.deck())
        #expect(state.librarySize == 90)
        #expect(state.command.count == 1)
        #expect(state.command[0].isCommander)
        #expect(state.total == 91)
        #expect(state.isUntouched)
    }

    @Test func newGameShufflesWithTheSeedAndDrawsSeven() throws {
        var a = PlaytestState(snapshot: try Self.deck())
        var b = a
        var ga = SeededGenerator(seed: 7), gb = SeededGenerator(seed: 7)
        a.newGame(using: &ga)
        b.newGame(using: &gb)
        #expect(a.hand.count == 7)
        #expect(a.librarySize == 83)
        #expect(a.hand.map(\.card.name) == b.hand.map(\.card.name))
        #expect(a.library.map(\.id) == b.library.map(\.id))
        var gc = SeededGenerator(seed: 8)
        var c = PlaytestState(snapshot: try Self.deck())
        c.newGame(using: &gc)
        #expect(c.library.map(\.id) != a.library.map(\.id))
        #expect(a.total == 91)
    }

    @Test func londonMulliganDrawsSevenThenBottomsOnePerMulligan() throws {
        var state = PlaytestState(snapshot: try Self.deck())
        var rng = SeededGenerator(seed: 1)
        state.newGame(using: &rng)
        state.mulligan(using: &rng)
        #expect(state.hand.count == 7)
        #expect(state.pendingBottom == 1)
        #expect(state.librarySize == 83)
        state.mulligan(using: &rng)
        #expect(state.pendingBottom == 2)
        let first = state.hand[0].id
        let second = state.hand[1].id
        state.bottom(first)
        #expect(state.pendingBottom == 1)
        #expect(state.library.last?.id == first)
        state.bottom(second)
        #expect(state.pendingBottom == 0)
        #expect(state.hand.count == 5)
        #expect(state.library.suffix(2).map(\.id) == [first, second])
        // No more bottoming once the count is met.
        let third = state.hand[0].id
        state.bottom(third)
        #expect(state.hand.count == 5)
        #expect(state.total == 91)
    }

    @Test func drawStopsAtAnEmptyLibrary() throws {
        var state = PlaytestState(snapshot: try Self.deck(lands: 2, spells: 1, commander: false))
        #expect(state.draw(5) == 3)
        #expect(state.draw() == 0)
        #expect(state.hand.count == 3)
        #expect(state.librarySize == 0)
    }

    @Test func playTapAndNextTurn() throws {
        var state = PlaytestState(snapshot: try Self.deck())
        var rng = SeededGenerator(seed: 3)
        state.newGame(using: &rng)
        let land = try #require(state.hand.first(where: \.isLand) ?? state.library.first(where: \.isLand))
        state.play(land.id)
        #expect(state.zone(of: land.id) == .battlefield)
        #expect(state.landsOnBattlefield.count == 1)
        #expect(state.untappedLands == 1)
        state.toggleTap(land.id)
        #expect(state.untappedLands == 0)
        #expect(state.card(land.id)?.isTapped == true)
        let handBefore = state.hand.count
        state.nextTurn()
        #expect(state.turn == 2)
        #expect(state.untappedLands == 1)
        #expect(state.hand.count == handBefore + 1)
        #expect(state.total == 91)
    }

    @Test func movesConserveCopiesAndUntap() throws {
        var state = PlaytestState(snapshot: try Self.deck())
        var rng = SeededGenerator(seed: 5)
        state.newGame(using: &rng)
        let card = state.hand[0]
        state.play(card.id)
        state.toggleTap(card.id)
        state.move(card.id, to: .graveyard)
        #expect(state.zone(of: card.id) == .graveyard)
        #expect(state.card(card.id)?.isTapped == false)
        state.move(card.id, to: .exile)
        #expect(state.exile.map(\.id) == [card.id])
        state.move(card.id, to: .library, libraryEnd: .top)
        #expect(state.library.first?.id == card.id)
        state.move(card.id, to: .library, libraryEnd: .bottom)
        #expect(state.library.last?.id == card.id)
        #expect(state.library.filter { $0.id == card.id }.count == 1)
        state.move(card.id, to: .hand)
        #expect(state.zone(of: card.id) == .hand)
        #expect(state.total == 91)
        // A missing id is ignored.
        state.move(UUID(), to: .graveyard)
        #expect(state.total == 91)
    }

    @Test func commanderCastsAndReturnsToCommand() throws {
        var state = PlaytestState(snapshot: try Self.deck())
        let commander = state.command[0]
        state.play(commander.id)
        #expect(state.command.isEmpty)
        #expect(state.spellsOnBattlefield.map(\.id) == [commander.id])
        state.move(commander.id, to: .command)
        #expect(state.command.map(\.id) == [commander.id])
        state.newGame()
        #expect(state.command.count == 1)
        #expect(state.hand.count == 7)
        #expect(state.total == 91)
    }

    @Test func aDeckWithoutACommanderHasNoCommandZone() throws {
        let state = PlaytestState(snapshot: try Self.deck(commander: false))
        #expect(state.command.isEmpty)
        #expect(state.total == 90)
    }
}
