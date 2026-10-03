//
//  Playtest.swift
//  magic-hat
//
//  Goldfishing a deck: the zones of a solitaire game and the moves between
//  them, as a plain value so the screen is a view of it and the rules are
//  tested without one. Library, hand, battlefield, graveyard, exile and
//  the command zone; shuffle, draw, a London mulligan (seven again, then
//  as many to the bottom as mulligans taken), a turn (untap, draw), and
//  any card to any zone. No rules engine beyond that — it is a table, not
//  an opponent: the player taps and moves cards the way they would with
//  real ones, and the app keeps count and shuffles honestly.
//
//  The shuffle takes any RandomNumberGenerator, so tests seed one and the
//  app uses the system's.
//

import Foundation

/// One physical card on the table: the printing it is, and whether it is
/// tapped. Copies of the same card are distinct instances.
nonisolated struct PlaytestCard: Identifiable, Hashable, Sendable {
    let id: UUID
    let card: CardItem
    var isTapped = false
    /// Started in the command zone: leaving the battlefield offers the
    /// command zone as a home, as the rules allow.
    let isCommander: Bool

    init(card: CardItem, isCommander: Bool = false) {
        id = UUID()
        self.card = card
        self.isCommander = isCommander
    }

    var isLand: Bool { (card.typeLine ?? "").contains("Land") }
}

nonisolated enum PlaytestZone: String, CaseIterable, Hashable, Sendable, Identifiable {
    case library, hand, battlefield, graveyard, exile, command

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: return "Library"
        case .hand: return "Hand"
        case .battlefield: return "Battlefield"
        case .graveyard: return "Graveyard"
        case .exile: return "Exile"
        case .command: return "Command Zone"
        }
    }
}

/// Where in the library a card goes.
nonisolated enum LibraryEnd: Sendable { case top, bottom }

nonisolated struct PlaytestState: Hashable, Sendable {
    /// Top of the library is the first element.
    private(set) var library: [PlaytestCard] = []
    private(set) var hand: [PlaytestCard] = []
    private(set) var battlefield: [PlaytestCard] = []
    private(set) var graveyard: [PlaytestCard] = []
    private(set) var exile: [PlaytestCard] = []
    private(set) var command: [PlaytestCard] = []
    private(set) var turn = 1
    private(set) var mulligans = 0
    /// Cards still to put on the bottom after a London mulligan.
    private(set) var pendingBottom = 0
    /// Each card to its starting zone, for New Game.
    private let deck: [PlaytestCard]

    static let openingHand = 7

    /// The deck's played boards: every copy of every mainboard card in the
    /// library, the commanders in the command zone.
    init(snapshot: DeckSnapshot) {
        var cards: [PlaytestCard] = []
        for item in snapshot.commanders { cards.append(PlaytestCard(card: item.card, isCommander: true)) }
        for item in snapshot.sections.flatMap(\.items) {
            for _ in 0..<max(1, item.quantity) { cards.append(PlaytestCard(card: item.card)) }
        }
        deck = cards
        library = cards.filter { !$0.isCommander }
        command = cards.filter(\.isCommander)
    }

    var librarySize: Int { library.count }
    /// Nothing drawn or played yet: the table as it is before the first game.
    var isUntouched: Bool { hand.isEmpty && battlefield.isEmpty && graveyard.isEmpty && exile.isEmpty && turn == 1 }

    // MARK: A game

    /// Everything back where it started, shuffled, seven drawn.
    mutating func newGame<G: RandomNumberGenerator>(using rng: inout G) {
        library = deck.filter { !$0.isCommander }.map { var c = $0; c.isTapped = false; return c }
        command = deck.filter(\.isCommander).map { var c = $0; c.isTapped = false; return c }
        hand = []; battlefield = []; graveyard = []; exile = []
        turn = 1
        mulligans = 0
        pendingBottom = 0
        shuffle(using: &rng)
        draw(Self.openingHand)
    }

    mutating func newGame() {
        var rng = SystemRandomNumberGenerator()
        newGame(using: &rng)
    }

    mutating func shuffle<G: RandomNumberGenerator>(using rng: inout G) {
        library.shuffle(using: &rng)
    }

    mutating func shuffle() {
        var rng = SystemRandomNumberGenerator()
        shuffle(using: &rng)
    }

    /// Draws up to `n`; an empty library draws nothing (the table doesn't
    /// decide the game).
    @discardableResult
    mutating func draw(_ n: Int = 1) -> Int {
        let count = min(n, library.count)
        hand.append(contentsOf: library.prefix(count))
        library.removeFirst(count)
        return count
    }

    /// London mulligan: the hand goes back, the library is shuffled, seven
    /// are drawn, and one more card than the last time must go to the
    /// bottom (`pendingBottom`), chosen by the player with `bottom(_:)`.
    mutating func mulligan<G: RandomNumberGenerator>(using rng: inout G) {
        library.append(contentsOf: hand)
        hand = []
        mulligans += 1
        shuffle(using: &rng)
        draw(Self.openingHand)
        pendingBottom = min(mulligans, hand.count)
    }

    mutating func mulligan() {
        var rng = SystemRandomNumberGenerator()
        mulligan(using: &rng)
    }

    /// One of the mulligan's cards to the bottom of the library.
    mutating func bottom(_ id: UUID) {
        guard pendingBottom > 0, let i = hand.firstIndex(where: { $0.id == id }) else { return }
        library.append(hand.remove(at: i))
        pendingBottom -= 1
    }

    /// Untap everything, draw one.
    mutating func nextTurn() {
        turn += 1
        for i in battlefield.indices { battlefield[i].isTapped = false }
        draw()
    }

    // MARK: Moving cards

    mutating func toggleTap(_ id: UUID) {
        guard let i = battlefield.firstIndex(where: { $0.id == id }) else { return }
        battlefield[i].isTapped.toggle()
    }

    /// Takes the card out of whichever zone holds it and puts it in
    /// `zone` — untapped, and at the chosen end of the library.
    mutating func move(_ id: UUID, to zone: PlaytestZone, libraryEnd: LibraryEnd = .top) {
        guard var card = remove(id) else { return }
        card.isTapped = false
        switch zone {
        case .library:
            if libraryEnd == .top { library.insert(card, at: 0) } else { library.append(card) }
        case .hand: hand.append(card)
        case .battlefield: battlefield.append(card)
        case .graveyard: graveyard.append(card)
        case .exile: exile.append(card)
        case .command: command.append(card)
        }
    }

    /// Plays from the hand (or casts from the command zone): onto the
    /// battlefield.
    mutating func play(_ id: UUID) { move(id, to: .battlefield) }

    func zone(of id: UUID) -> PlaytestZone? {
        if library.contains(where: { $0.id == id }) { return .library }
        if hand.contains(where: { $0.id == id }) { return .hand }
        if battlefield.contains(where: { $0.id == id }) { return .battlefield }
        if graveyard.contains(where: { $0.id == id }) { return .graveyard }
        if exile.contains(where: { $0.id == id }) { return .exile }
        if command.contains(where: { $0.id == id }) { return .command }
        return nil
    }

    func card(_ id: UUID) -> PlaytestCard? {
        (library + hand + battlefield + graveyard + exile + command).first { $0.id == id }
    }

    private mutating func remove(_ id: UUID) -> PlaytestCard? {
        if let i = library.firstIndex(where: { $0.id == id }) { return library.remove(at: i) }
        if let i = hand.firstIndex(where: { $0.id == id }) { return hand.remove(at: i) }
        if let i = battlefield.firstIndex(where: { $0.id == id }) { return battlefield.remove(at: i) }
        if let i = graveyard.firstIndex(where: { $0.id == id }) { return graveyard.remove(at: i) }
        if let i = exile.firstIndex(where: { $0.id == id }) { return exile.remove(at: i) }
        if let i = command.firstIndex(where: { $0.id == id }) { return command.remove(at: i) }
        return nil
    }

    /// Every card, wherever it is — copies are conserved, as tests check.
    var total: Int { library.count + hand.count + battlefield.count + graveyard.count + exile.count + command.count }

    // MARK: Reading the table

    var landsOnBattlefield: [PlaytestCard] { battlefield.filter(\.isLand) }
    var spellsOnBattlefield: [PlaytestCard] { battlefield.filter { !$0.isLand } }
    /// Untapped lands: a rough "mana available" for the status line.
    var untappedLands: Int { landsOnBattlefield.filter { !$0.isTapped }.count }
}

/// A seedable generator for tests (SplitMix64), so a shuffle is repeatable.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
