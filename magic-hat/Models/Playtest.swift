//
//  Playtest.swift
//  magic-hat
//
//  Goldfishing a deck: a solitaire game played by the turn structure and
//  the zone rules of real Magic, as a plain value so the screen is a view
//  of it and the rules are tested without one.
//
//  What it follows, because it is what a table does:
//  - The opening hand is decided before turn one: keep, or a London
//    mulligan (seven again, then one card to the bottom per mulligan; in
//    Commander, Oathbreaker and Brawl the first mulligan is free).
//  - Whoever plays first in a two-player game skips their first draw; in
//    a multiplayer format (Commander, Oathbreaker) nobody does.
//  - A turn untaps, draws, and allows one land; ending it discards down to
//    seven (unless something says there is no maximum).
//  - A land is played, not cast. A permanent spell resolves onto the
//    battlefield; an instant or sorcery resolves into the graveyard (cast
//    from the graveyard it is exiled, an adventure goes to exile to be cast
//    from there, an Oathbreaker's signature spell goes home) and is never
//    a permanent. Nothing that isn't a permanent can be put onto the
//    battlefield.
//  - Spells are paid for: untapped lands and mana abilities are tapped
//    (see PlaytestPayer), and a commander costs two more for each time it
//    was cast from the command zone.
//  - Creatures are summoning sick the turn they arrive (unless they have
//    haste); attacking taps them (unless vigilance), and the damage comes
//    off the opponent's life — or adds up as commander damage.
//  - Tokens cease to exist when they leave the battlefield; +1/+1 and
//    -1/-1 counters cancel out, and a creature with no toughness or a
//    planeswalker with no loyalty dies.
//
//  No opponent and no stack to respond on: a spell resolves as it is
//  cast. Where the reading can't tell (a cost it doesn't know, a land
//  beyond the first) the player decides, and the state lets them.
//
//  The shuffle takes any RandomNumberGenerator, so tests seed one and the
//  app uses the system's.
//

import Foundation

// MARK: - Cards

/// The parts of a card that never change while it is played, shared by
/// reference so a state (and every undo step) copies a pointer per card.
nonisolated final class PlaytestCardBase: Hashable, Sendable {
    let card: CardItem
    let info: PlaytestCardInfo

    init(_ card: CardItem) {
        self.card = card
        info = PlaytestCardInfo(card)
    }

    static func == (a: PlaytestCardBase, b: PlaytestCardBase) -> Bool { a === b || a.card == b.card }
    func hash(into hasher: inout Hasher) { hasher.combine(card.id) }
}

nonisolated enum PlaytestCounter: String, CaseIterable, Hashable, Sendable, Identifiable {
    case plusOne, minusOne, loyalty, charge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plusOne: return "+1/+1"
        case .minusOne: return "−1/−1"
        case .loyalty: return "Loyalty"
        case .charge: return "Counter"
        }
    }
}

/// One physical card at the table. Copies of the same card are distinct
/// instances; a token is an instance with no card behind it in the deck.
nonisolated struct PlaytestCard: Identifiable, Hashable, Sendable {
    let id: UUID
    let base: PlaytestCardBase
    let isCommander: Bool
    let isToken: Bool
    var isTapped = false
    /// Showing its back: transformed, or a modal card played as its back.
    var showsBack = false
    var counters: [PlaytestCounter: Int] = [:]
    /// The turn it came onto the battlefield; nil anywhere else.
    var enteredTurn: Int?
    /// In exile on an adventure: it may be cast from there as the creature.
    var onAdventure = false

    init(card: CardItem, isCommander: Bool = false, isToken: Bool = false) {
        id = UUID()
        base = PlaytestCardBase(card)
        self.isCommander = isCommander
        self.isToken = isToken
    }

    private init(copying other: PlaytestCard) {
        id = UUID()
        base = other.base
        isCommander = false
        isToken = true
        showsBack = other.showsBack
    }

    /// A token copy of this card (Clone, populate).
    func tokenCopy() -> PlaytestCard { PlaytestCard(copying: self) }

    var card: CardItem { base.card }
    var info: PlaytestCardInfo { base.info }
    /// The face up: the back once transformed or played as its back.
    var face: PlaytestFace { showsBack ? (info.back ?? info.front) : info.front }
    var name: String { face.name }
    var isLand: Bool { face.isLand }
    var isCreature: Bool { face.isCreature }
    /// The image of the face up (a split or adventure card has one image).
    var imageURL: String? { showsBack ? (card.backImageURL ?? card.imageURL) : card.imageURL }

    /// Where on the table it sits: lands nearest the player, then the other
    /// noncreature permanents, creatures in front.
    var tableRow: PlaytestRow {
        if face.isLand { return .lands }
        if face.isCreature { return .creatures }
        return .permanents
    }

    /// Printed power and toughness plus counters; nil for a face whose
    /// numbers aren't known (a back face, a `*`).
    var power: Int? {
        guard !showsBack, let p = info.power else { return nil }
        return p + (counters[.plusOne] ?? 0) - (counters[.minusOne] ?? 0)
    }
    var toughness: Int? {
        guard !showsBack, let t = info.toughness else { return nil }
        return t + (counters[.plusOne] ?? 0) - (counters[.minusOne] ?? 0)
    }
    var isBoosted: Bool { (counters[.plusOne] ?? 0) > 0 }
    var isShrunk: Bool { (counters[.minusOne] ?? 0) > 0 }

    /// Hasn't been under control since the turn began, and can't attack or
    /// use {T} abilities — unless it has haste.
    func isSummoningSick(on turn: Int) -> Bool {
        face.isCreature && enteredTurn == turn && !face.keywords.contains(.haste)
    }

    /// Off the battlefield: untapped, front up, no counters.
    fileprivate mutating func leaveBattlefield() {
        isTapped = false
        showsBack = false
        counters = [:]
        enteredTurn = nil
    }
}

/// The battlefield's rows, far to near.
nonisolated enum PlaytestRow: Int, CaseIterable, Hashable, Sendable, Identifiable {
    case creatures, permanents, lands

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .creatures: return "Creatures"
        case .permanents: return "Other Permanents"
        case .lands: return "Lands"
        }
    }
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

    /// "to the graveyard", for the log.
    var phrase: String {
        switch self {
        case .library: return "into the library"
        case .hand: return "to hand"
        case .battlefield: return "onto the battlefield"
        case .graveyard: return "to the graveyard"
        case .exile: return "into exile"
        case .command: return "to the command zone"
        }
    }
}

/// Where in the library a card goes.
nonisolated enum LibraryEnd: Sendable { case top, bottom }

// MARK: - The game

/// What the format changes at the table.
nonisolated struct PlaytestRules: Hashable, Sendable {
    var startingLife: Int
    /// Nobody skips their first draw in a multiplayer game (103.8c).
    var isMultiplayer: Bool
    /// Multiplayer and Brawl: the first mulligan doesn't count (103.5c).
    var freeMulligan: Bool
    /// 21 combat damage from one commander loses the game (903.10a).
    var commanderDamage: Bool
    var handSize = 7
    var openingHand = 7

    init(format: DeckFormat) {
        switch format {
        case .commander:
            startingLife = 40; isMultiplayer = true; freeMulligan = true; commanderDamage = true
        case .oathbreaker:
            startingLife = 20; isMultiplayer = true; freeMulligan = true; commanderDamage = false
        case .brawl:
            startingLife = 25; isMultiplayer = false; freeMulligan = true; commanderDamage = false
        default:
            startingLife = 20; isMultiplayer = false; freeMulligan = false; commanderDamage = false
        }
    }

    static let commanderDamageLimit = 21
}

nonisolated enum PlaytestPhase: Hashable, Sendable {
    /// Before turn one: keep the hand or mulligan.
    case opening
    /// Kept after mulligans: this many cards still go to the bottom.
    case bottoming(Int)
    /// The turn is on.
    case main
    /// Ending the turn: this many cards still to discard to hand size.
    case cleanup(Int)

    var isPlaying: Bool { self == .main }
}

/// How a card from hand (or another zone) is played.
nonisolated enum PlaytestPlay: Hashable, Sendable {
    /// As printed: a land is played, a spell cast.
    case front
    /// The other face or half: a modal card's back, a split card's second
    /// half, an adventure.
    case back
    /// Onto the battlefield without casting it (permanents only).
    case free
}

/// Why a play needs the player's say-so, or can't happen.
nonisolated enum PlaytestPlayIssue: Hashable, Sendable {
    case notMainPhase
    case landAlreadyPlayed
    case cannotPay(cost: String, available: Int)
    case notAPermanent
}

nonisolated struct PlaytestPlayResult: Hashable, Sendable {
    let name: String
    /// Where it ended up: the battlefield, or for an instant or sorcery the
    /// graveyard (exile, the command zone).
    let zone: PlaytestZone
    let isLand: Bool
    /// Sources tapped to pay for it.
    let tapped: Int
    let lifePaid: Int
}

/// Library manipulation from the top: what each may do with a card.
nonisolated enum PlaytestLook: Hashable, Sendable {
    case scry, surveil, look

    var destinations: [PlaytestTopDestination] {
        switch self {
        case .scry: return [.top, .bottom]
        case .surveil: return [.top, .graveyard]
        case .look: return [.top, .bottom, .hand, .graveyard, .exile, .battlefield]
        }
    }

    var label: String {
        switch self {
        case .scry: return "Scry"
        case .surveil: return "Surveil"
        case .look: return "Look at"
        }
    }
}

nonisolated enum PlaytestTopDestination: String, CaseIterable, Hashable, Sendable, Identifiable {
    case top, bottom, hand, graveyard, exile, battlefield
    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .hand: return "Hand"
        case .graveyard: return "Graveyard"
        case .exile: return "Exile"
        case .battlefield: return "Battlefield"
        }
    }
}

nonisolated enum PlaytestSearchDestination: String, CaseIterable, Hashable, Sendable, Identifiable {
    case hand, battlefield, battlefieldTapped, graveyard, top
    var id: String { rawValue }

    /// The search sheet's menu item.
    var label: String {
        switch self {
        case .hand: return "To Hand"
        case .battlefield: return "Onto the Battlefield"
        case .battlefieldTapped: return "Onto the Battlefield Tapped"
        case .graveyard: return "To the Graveyard"
        case .top: return "On Top of the Library"
        }
    }

    var systemImage: String {
        switch self {
        case .hand: return "hand.raised"
        case .battlefield: return "arrow.up.right"
        case .battlefieldTapped: return "arrow.turn.right.down"
        case .graveyard: return "archivebox"
        case .top: return "arrow.up.to.line"
        }
    }

    /// Whether it puts the card onto the battlefield (permanents only).
    var isBattlefield: Bool { self == .battlefield || self == .battlefieldTapped }
}

/// One line of the game log.
nonisolated struct PlaytestEvent: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case game, draw, land, cast, resolve, move, token, combat, life, library, counter
    }

    let id: Int
    let turn: Int
    let kind: Kind
    let text: String
    /// Worth telling the player: something moved that their tap didn't show
    /// (a spell resolving into the graveyard, a token gone, a search).
    let isNotable: Bool
}

nonisolated struct PlaytestAttackResult: Hashable, Sendable {
    let attackers: Int
    let damage: Int
    let lifeGained: Int
}

/// Cards that look the same on the table, drawn as one pile.
nonisolated struct PlaytestStack: Identifiable, Hashable, Sendable {
    let cards: [PlaytestCard]
    var id: UUID { cards[0].id }
    /// The card drawn on top, whose state the pile shows.
    var top: PlaytestCard { cards[0] }
    /// The card a tap acts on: the last, so the pile keeps its identity.
    var actionCard: PlaytestCard { cards[cards.count - 1] }
    var count: Int { cards.count }
}

nonisolated struct PlaytestState: Hashable, Sendable {
    let rules: PlaytestRules
    /// Top of the library is the first element.
    private(set) var library: [PlaytestCard] = []
    private(set) var hand: [PlaytestCard] = []
    private(set) var battlefield: [PlaytestCard] = []
    private(set) var graveyard: [PlaytestCard] = []
    private(set) var exile: [PlaytestCard] = []
    private(set) var command: [PlaytestCard] = []
    private(set) var phase: PlaytestPhase = .opening
    /// 0 while the opening hand is decided.
    private(set) var turn = 0
    private(set) var mulligans = 0
    /// Two-player games: whoever plays first skips their first draw. Chosen
    /// with the opening hand.
    private(set) var onThePlay = true
    private(set) var life: Int
    private(set) var opponentLife: Int
    /// Combat damage each commander has dealt the opponent.
    private(set) var commanderDamage: [UUID: Int] = [:]
    private(set) var landsPlayed = 0
    private(set) var spellsCast = 0
    /// Casts from the command zone, per commander: the tax is two each.
    private(set) var commanderCasts: [UUID: Int] = [:]
    /// The turn the opponent fell to 0 (or to 21 commander damage).
    private(set) var defeatedOnTurn: Int?
    private(set) var log: [PlaytestEvent] = []
    /// Each card as dealt, for New Game.
    private let deck: [PlaytestCard]

    /// The deck's played boards: every copy of every mainboard card in the
    /// library, the commanders in the command zone. No hand yet: `newGame`.
    init(snapshot: DeckSnapshot) {
        rules = PlaytestRules(format: snapshot.format)
        var cards: [PlaytestCard] = []
        for item in snapshot.commanders { cards.append(PlaytestCard(card: item.card, isCommander: true)) }
        for item in snapshot.sections.flatMap(\.items) {
            for _ in 0..<max(1, item.quantity) { cards.append(PlaytestCard(card: item.card)) }
        }
        deck = cards
        library = cards.filter { !$0.isCommander }
        command = cards.filter(\.isCommander)
        life = rules.startingLife
        opponentLife = rules.startingLife
    }

    var librarySize: Int { library.count }
    /// Whether the deck has commanders at all: the command zone is shown
    /// even while they are out of it.
    var hasCommanders: Bool { deck.contains(where: \.isCommander) }
    var isUntouched: Bool { hand.isEmpty && battlefield.isEmpty && graveyard.isEmpty && exile.isEmpty && turn == 0 }
    /// Every card of the deck, wherever it is — copies are conserved, as
    /// the tests check. Tokens aren't cards of the deck.
    var total: Int { allCards.filter { !$0.isToken }.count }
    var tokenCount: Int { battlefield.filter(\.isToken).count }
    /// The draw this game skips: on the play in a two-player game.
    var skipsFirstDraw: Bool { onThePlay && !rules.isMultiplayer }

    // MARK: Starting a game

    /// Everything back where it started, shuffled, seven drawn, and the
    /// hand to keep or mulligan.
    mutating func newGame<G: RandomNumberGenerator>(using rng: inout G) {
        library = deck.filter { !$0.isCommander }.map(Self.fresh)
        command = deck.filter(\.isCommander).map(Self.fresh)
        hand = []; battlefield = []; graveyard = []; exile = []
        phase = .opening
        turn = 0
        mulligans = 0
        life = rules.startingLife
        opponentLife = rules.startingLife
        commanderDamage = [:]
        commanderCasts = [:]
        landsPlayed = 0
        spellsCast = 0
        defeatedOnTurn = nil
        log = []
        shuffle(using: &rng)
        let n = take(rules.openingHand)
        record(.game, "New game · drew \(n)")
    }

    mutating func newGame() {
        var rng = SystemRandomNumberGenerator()
        newGame(using: &rng)
    }

    private static func fresh(_ card: PlaytestCard) -> PlaytestCard {
        var card = card
        card.leaveBattlefield()
        card.onAdventure = false
        return card
    }

    mutating func setOnThePlay(_ value: Bool) {
        guard turn == 0 else { return }
        onThePlay = value
    }

    /// How many cards keeping now puts on the bottom.
    var cardsToBottom: Int { min(hand.count, max(0, mulligans - (rules.freeMulligan ? 1 : 0))) }
    /// The hand size keeping now leaves.
    var keepSize: Int { hand.count - cardsToBottom }

    /// London mulligan: the hand goes back, the library is shuffled and
    /// seven are drawn again; the bottoming comes on keeping.
    mutating func mulligan<G: RandomNumberGenerator>(using rng: inout G) {
        guard phase == .opening else { return }
        library.append(contentsOf: hand)
        hand = []
        mulligans += 1
        shuffle(using: &rng)
        take(rules.openingHand)
        record(.game, mulligans == 1 && rules.freeMulligan ? "Free mulligan" : "Mulligan to \(keepSize)")
    }

    mutating func mulligan() {
        var rng = SystemRandomNumberGenerator()
        mulligan(using: &rng)
    }

    /// Keeps the hand: straight to turn one, or first the mulligan's cards
    /// to the bottom.
    mutating func keep() {
        guard phase == .opening else { return }
        let n = cardsToBottom
        record(.game, "Kept \(keepSize)" + (n > 0 ? " · \(n) to the bottom" : ""))
        if n > 0 { phase = .bottoming(n) } else { begin() }
    }

    /// One of the mulligan's cards to the bottom of the library.
    mutating func bottom(_ id: UUID) {
        guard case .bottoming(let n) = phase, let i = hand.firstIndex(where: { $0.id == id }) else { return }
        library.append(hand.remove(at: i))
        if n > 1 { phase = .bottoming(n - 1) } else { begin() }
    }

    private mutating func begin() {
        turn = 1
        record(.game, rules.isMultiplayer ? "Turn 1" : (onThePlay ? "Turn 1 · on the play" : "Turn 1 · on the draw"))
        startTurn(draws: !skipsFirstDraw)
    }

    // MARK: Turns

    /// Untap, upkeep, draw: every permanent untaps, the land drop resets.
    private mutating func startTurn(draws: Bool) {
        phase = .main
        landsPlayed = 0
        spellsCast = 0
        untapAll()
        if draws { draw() }
    }

    var hasNoMaximumHandSize: Bool { battlefield.contains { $0.info.noMaximumHandSize } }

    /// End step and cleanup: down to hand size, then the next turn.
    mutating func endTurn() {
        guard phase == .main else { return }
        let excess = hasNoMaximumHandSize ? 0 : hand.count - rules.handSize
        if excess > 0 {
            phase = .cleanup(excess)
        } else {
            nextTurn()
        }
    }

    /// Discards a card: during cleanup, one of the cards over hand size.
    mutating func discard(_ id: UUID) {
        guard let i = hand.firstIndex(where: { $0.id == id }) else { return }
        let card = hand.remove(at: i)
        graveyard.append(card)
        record(.move, "Discarded \(card.name)")
        if case .cleanup(let n) = phase {
            if n > 1 { phase = .cleanup(n - 1) } else { nextTurn() }
        }
    }

    private mutating func nextTurn() {
        turn += 1
        record(.game, "Turn \(turn)")
        startTurn(draws: true)
    }

    // MARK: Library

    mutating func shuffle<G: RandomNumberGenerator>(using rng: inout G) {
        library.shuffle(using: &rng)
    }

    mutating func shuffle() {
        var rng = SystemRandomNumberGenerator()
        shuffle(using: &rng)
    }

    /// Draws up to `n`; an empty library draws nothing (the table doesn't
    /// decide the game) and says so.
    @discardableResult
    mutating func draw(_ n: Int = 1) -> Int {
        let drawn = Array(library.prefix(n))
        let count = take(n)
        if count == 0 {
            record(.draw, "The library is empty", notable: true)
        } else {
            record(.draw, count == 1 ? "Drew \(drawn[0].name)" : "Drew \(count) cards")
        }
        return count
    }

    @discardableResult
    private mutating func take(_ n: Int) -> Int {
        let count = min(max(0, n), library.count)
        hand.append(contentsOf: library.prefix(count))
        library.removeFirst(count)
        return count
    }

    /// The top `n` into the graveyard.
    @discardableResult
    mutating func mill(_ n: Int) -> Int {
        let milled = Array(library.prefix(n))
        library.removeFirst(milled.count)
        graveyard.append(contentsOf: milled)
        if !milled.isEmpty { record(.library, "Milled " + Self.names(milled), notable: true) }
        return milled.count
    }

    func top(_ n: Int) -> [PlaytestCard] { Array(library.prefix(n)) }

    /// Scry, surveil or look at the top cards: each placement in order;
    /// those going on top go in that order (the first on top), those to
    /// the bottom likewise.
    mutating func arrangeTop(_ placements: [(id: UUID, to: PlaytestTopDestination)], as look: PlaytestLook) {
        var taken: [UUID: PlaytestCard] = [:]
        for placement in placements {
            guard look.destinations.contains(placement.to),
                  let i = library.firstIndex(where: { $0.id == placement.id }) else { continue }
            taken[placement.id] = library.remove(at: i)
        }
        guard !taken.isEmpty else { return }
        var tops: [PlaytestCard] = []
        var bottoms: [PlaytestCard] = []
        var away: [String] = []
        for placement in placements {
            guard var card = taken[placement.id] else { continue }
            switch placement.to {
            case .top: tops.append(card)
            case .bottom: bottoms.append(card)
            case .hand: hand.append(card); away.append("\(card.name) to hand")
            case .graveyard: graveyard.append(card); away.append("\(card.name) to the graveyard")
            case .exile: exile.append(card); away.append("\(card.name) into exile")
            case .battlefield:
                if card.info.front.isPermanent {
                    enter(&card)
                    battlefield.append(card)
                    away.append("\(card.name) onto the battlefield")
                } else {
                    tops.append(card)
                }
            }
        }
        library.insert(contentsOf: tops, at: 0)
        library.append(contentsOf: bottoms)
        var parts: [String] = []
        if !tops.isEmpty { parts.append("\(tops.count) on top") }
        if !bottoms.isEmpty { parts.append("\(bottoms.count) on the bottom") }
        parts += away
        record(.library, "\(look.label) \(taken.count): " + parts.joined(separator: ", "), notable: look != .scry || !bottoms.isEmpty)
    }

    /// Takes a card from the library, shuffles, and puts it where the
    /// search said (on top after the shuffle, as Vampiric Tutor does).
    @discardableResult
    mutating func search<G: RandomNumberGenerator>(take id: UUID, to destination: PlaytestSearchDestination, using rng: inout G) -> Bool {
        guard let i = library.firstIndex(where: { $0.id == id }) else { return false }
        if destination == .battlefield || destination == .battlefieldTapped, !library[i].info.front.isPermanent { return false }
        var card = library.remove(at: i)
        library.shuffle(using: &rng)
        switch destination {
        case .hand: hand.append(card)
        case .graveyard: graveyard.append(card)
        case .top: library.insert(card, at: 0)
        case .battlefield, .battlefieldTapped:
            enter(&card)
            if destination == .battlefieldTapped { card.isTapped = true }
            battlefield.append(card)
        }
        let whereTo = destination == .top ? "on top" : destination == .battlefieldTapped ? "onto the battlefield tapped"
            : PlaytestZone(rawValue: destination.rawValue)?.phrase ?? ""
        record(.library, "Searched for \(card.name), \(whereTo) · shuffled", notable: true)
        return true
    }

    @discardableResult
    mutating func search(take id: UUID, to destination: PlaytestSearchDestination) -> Bool {
        var rng = SystemRandomNumberGenerator()
        return search(take: id, to: destination, using: &rng)
    }

    // MARK: Playing cards

    /// The ways a card can be played from where it is.
    func playOptions(_ id: UUID) -> [PlaytestPlay] {
        guard let zone = zone(of: id), let card = card(id) else { return [] }
        let info = card.info
        switch zone {
        case .hand:
            var options: [PlaytestPlay] = [.front]
            if info.backIsPlayable { options.append(.back) }
            if info.front.isPermanent, !info.front.isLand { options.append(.free) }
            return options
        case .command:
            return [.front]
        case .exile:
            if card.onAdventure { return [.front] }
            return info.backIsPlayable ? [.front, .back] : [.front]
        case .graveyard:
            // Disturb's back is cast from here, and only from here.
            if info.disturbCost != nil { return [.front, .back] }
            return info.backIsPlayable && info.layout == .split ? [.front, .back] : [.front]
        case .library, .battlefield:
            return []
        }
    }

    /// The face a play puts forward.
    func face(_ id: UUID, for play: PlaytestPlay) -> PlaytestFace? {
        guard let card = card(id) else { return nil }
        return play == .back ? card.info.back : card.info.front
    }

    /// The cost of casting it this way, commander tax included; nil for a
    /// land or a free put. A cost the card doesn't state is tax only and
    /// `isKnown` false.
    func cost(of id: UUID, as play: PlaytestPlay) -> PlaytestCost? {
        guard play != .free, let face = face(id, for: play), !face.isLand else { return nil }
        let zone = zone(of: id)
        let tax = zone == .command ? 2 * (commanderCasts[id] ?? 0) : 0
        // A disturbed back costs what the front's keyword says; the face
        // itself has no cost.
        let printed = play == .back && zone == .graveyard ? (card(id)?.info.disturbCost ?? face.cost) : face.cost
        var cost = PlaytestCost(printed ?? "", tax: tax)
        cost.isKnown = printed != nil
        return cost
    }

    /// The way a drag onto the battlefield plays the card: the first face
    /// (front, then back) that needs no say-so — a modal card's land back
    /// while the land drop is ready, its spell once the land is played —
    /// else the front, which then asks. Only a back that stays on the
    /// battlefield is a candidate: an adventure or a split card's other
    /// instant is cast from the card's sheet, never by a drag.
    func dragPlay(_ id: UUID, autoPay: Bool = true) -> PlaytestPlay {
        guard let card = card(id) else { return .front }
        let candidates = playOptions(id).filter { play in
            play == .front || (play == .back && card.info.back.map { $0.isLand || $0.isPermanent } == true)
        }
        return candidates.first { issue(playing: id, as: $0, autoPay: autoPay) == nil } ?? .front
    }

    /// What stands in the way of playing it: nil when it can just happen.
    func issue(playing id: UUID, as play: PlaytestPlay = .front, autoPay: Bool = true) -> PlaytestPlayIssue? {
        guard phase == .main else { return .notMainPhase }
        guard let face = face(id, for: play) else { return nil }
        if play == .free { return face.isPermanent ? nil : .notAPermanent }
        if face.isLand { return landsPlayed > 0 ? .landAlreadyPlayed : nil }
        if autoPay, let cost = cost(of: id, as: play), !cost.isFree, PlaytestPayer.pay(cost, from: paySources()) == nil {
            return .cannotPay(cost: cost.text, available: manaAvailable)
        }
        return nil
    }

    /// Plays the card: a land onto the battlefield (the turn's land drop),
    /// a spell paid for and resolved — a permanent onto the battlefield, an
    /// instant or sorcery into the graveyard (or exile, or home). With
    /// `force`, an extra land is played and a spell the sources can't pay
    /// for is cast without tapping them. Nil when it can't be played.
    @discardableResult
    mutating func play(_ id: UUID, as play: PlaytestPlay = .front, autoPay: Bool = true, force: Bool = false) -> PlaytestPlayResult? {
        var rng = SystemRandomNumberGenerator()
        return self.play(id, as: play, autoPay: autoPay, force: force, using: &rng)
    }

    /// `play` with the shuffle an omen needs.
    @discardableResult
    mutating func play<G: RandomNumberGenerator>(_ id: UUID, as play: PlaytestPlay = .front, autoPay: Bool = true, force: Bool = false,
                                                 using rng: inout G) -> PlaytestPlayResult? {
        guard let from = zone(of: id), playOptions(id).contains(play), let face = face(id, for: play) else { return nil }
        let problem = issue(playing: id, as: play, autoPay: autoPay)
        switch problem {
        case .notMainPhase, .notAPermanent: return nil
        case .landAlreadyPlayed, .cannotPay: if !force { return nil }
        case nil: break
        }

        // Pay first, while the sources are where they were.
        var tapped = 0
        var lifePaid = 0
        if autoPay, let cost = cost(of: id, as: play), !cost.isFree, let payment = PlaytestPayer.pay(cost, from: paySources()) {
            for source in payment.tapped { setTapped(source, true) }
            tapped = payment.tapped.count
            lifePaid = payment.lifePaid
            life -= lifePaid
        }
        guard var card = remove(id) else { return nil }
        let layout = card.info.layout

        if play == .free {
            card.onAdventure = false
            enter(&card)
            battlefield.append(card)
            record(.move, "Put \(face.name) onto the battlefield")
            return PlaytestPlayResult(name: face.name, zone: .battlefield, isLand: face.isLand, tapped: 0, lifePaid: 0)
        }

        if face.isLand {
            landsPlayed += 1
            card.showsBack = play == .back && layout == .modal
            card.onAdventure = false
            enter(&card)
            battlefield.append(card)
            record(.land, "Played \(face.name)" + (landsPlayed > 1 ? " (land \(landsPlayed) this turn)" : "") + (card.isTapped ? ", tapped" : ""))
            return PlaytestPlayResult(name: face.name, zone: .battlefield, isLand: true, tapped: 0, lifePaid: 0)
        }

        spellsCast += 1
        if from == .command { commanderCasts[id, default: 0] += 1 }
        let paid = (tapped > 0 ? " · tapped \(tapped)" : "") + (lifePaid > 0 ? " · paid \(lifePaid) life" : "")

        if face.isPermanent {
            // A modal back, or a disturbed card cast transformed.
            card.showsBack = play == .back && (layout == .modal || layout == .transform)
            card.onAdventure = false
            enter(&card)
            battlefield.append(card)
            record(.cast, "Cast \(face.name)\(paid)")
            return PlaytestPlayResult(name: face.name, zone: .battlefield, isLand: false, tapped: tapped, lifePaid: lifePaid)
        }

        // An instant or sorcery: it resolves and goes where its rules say.
        if play == .back && layout == .omen {
            card.onAdventure = false
            library.append(card)
            library.shuffle(using: &rng)
            record(.resolve, "Cast \(face.name)\(paid) — shuffled into the library", notable: true)
            return PlaytestPlayResult(name: face.name, zone: .library, isLand: false, tapped: tapped, lifePaid: lifePaid)
        }
        let destination: PlaytestZone
        if play == .back && layout == .adventure && from == .hand {
            card.onAdventure = true
            destination = .exile
        } else if from == .graveyard {
            destination = .exile
        } else if from == .command && card.isCommander {
            destination = .command
        } else {
            destination = .graveyard
        }
        if destination != .exile { card.onAdventure = false }
        place(card, in: destination)
        let note = card.onAdventure ? " — on an adventure in exile" : " — \(destination.phrase)"
        record(.resolve, "Cast \(face.name)\(paid)\(note)", notable: true)
        return PlaytestPlayResult(name: face.name, zone: destination, isLand: false, tapped: tapped, lifePaid: lifePaid)
    }

    /// A permanent arriving: summoning sick this turn, tapped if it enters
    /// tapped, a planeswalker with its loyalty.
    private mutating func enter(_ card: inout PlaytestCard) {
        card.enteredTurn = turn
        card.counters = [:]
        card.isTapped = card.face.entersTapped
        if card.face.isPlaneswalker, !card.showsBack, let loyalty = card.info.loyalty {
            card.counters[.loyalty] = loyalty
        }
    }

    // MARK: Moving cards

    /// Takes the card out of whichever zone holds it and puts it in `zone`,
    /// as an effect would: a token that leaves the battlefield ceases to
    /// exist, only a permanent card can go onto the battlefield, only a
    /// commander to the command zone. False when it can't.
    @discardableResult
    mutating func move(_ id: UUID, to zone: PlaytestZone, libraryEnd: LibraryEnd = .top) -> Bool {
        guard let from = self.zone(of: id), let current = card(id) else { return false }
        if zone == from, zone != .library { return false }
        if zone == .battlefield, !current.info.front.isPermanent { return false }
        if zone == .command, !current.isCommander { return false }
        guard var card = remove(id) else { return false }
        if from == .battlefield, card.isToken {
            record(.token, "\(card.name) token left the battlefield and ceased to exist", notable: zone != .graveyard)
            return true
        }
        if from == .battlefield { card.leaveBattlefield() }
        if from == .exile { card.onAdventure = false }
        switch zone {
        case .library:
            if libraryEnd == .top { library.insert(card, at: 0) } else { library.append(card) }
            record(.move, "\(card.name) on the \(libraryEnd == .top ? "top" : "bottom") of the library")
        case .battlefield:
            enter(&card)
            battlefield.append(card)
            record(.move, "\(card.name) onto the battlefield")
        default:
            place(card, in: zone)
            record(.move, "\(card.name) \(zone.phrase)")
        }
        return true
    }

    private mutating func place(_ card: PlaytestCard, in zone: PlaytestZone) {
        switch zone {
        case .library: library.insert(card, at: 0)
        case .hand: hand.append(card)
        case .battlefield: battlefield.append(card)
        case .graveyard: graveyard.append(card)
        case .exile: exile.append(card)
        case .command: command.append(card)
        }
    }

    // MARK: The battlefield

    mutating func toggleTap(_ id: UUID) {
        guard let i = battlefield.firstIndex(where: { $0.id == id }) else { return }
        battlefield[i].isTapped.toggle()
    }

    mutating func setTapped(_ id: UUID, _ tapped: Bool) {
        guard let i = battlefield.firstIndex(where: { $0.id == id }) else { return }
        battlefield[i].isTapped = tapped
    }

    mutating func untapAll() {
        for i in battlefield.indices { battlefield[i].isTapped = false }
    }

    /// Turns a transforming card over.
    mutating func transform(_ id: UUID) {
        guard let i = battlefield.firstIndex(where: { $0.id == id }), battlefield[i].info.transforms else { return }
        battlefield[i].showsBack.toggle()
        record(.move, "Transformed into \(battlefield[i].name)")
    }

    /// Adds (or with a negative amount removes) counters, then what the
    /// counters decide: +1/+1 and −1/−1 cancel, a creature with 0 toughness
    /// and a planeswalker with no loyalty die.
    mutating func addCounters(_ kind: PlaytestCounter, _ amount: Int, to id: UUID) {
        guard let i = battlefield.firstIndex(where: { $0.id == id }) else { return }
        var card = battlefield[i]
        let value = max(0, (card.counters[kind] ?? 0) + amount)
        card.counters[kind] = value == 0 && kind != .loyalty ? nil : value
        let plus = card.counters[.plusOne] ?? 0, minus = card.counters[.minusOne] ?? 0
        if plus > 0, minus > 0 {
            let n = min(plus, minus)
            card.counters[.plusOne] = plus == n ? nil : plus - n
            card.counters[.minusOne] = minus == n ? nil : minus - n
        }
        battlefield[i] = card
        record(.counter, "\(card.name): \(amount > 0 ? "+" : "")\(amount) \(kind.label)")
        if card.face.isCreature, let toughness = card.toughness, toughness <= 0 {
            dies(card, because: "0 toughness")
        } else if card.face.isPlaneswalker, kind == .loyalty, value <= 0 {
            dies(card, because: "no loyalty")
        }
    }

    private mutating func dies(_ card: PlaytestCard, because reason: String) {
        guard var dead = remove(card.id) else { return }
        if dead.isToken {
            record(.token, "\(dead.name) died (\(reason)) and ceased to exist", notable: true)
            return
        }
        dead.leaveBattlefield()
        graveyard.append(dead)
        record(.move, "\(dead.name) died (\(reason))", notable: true)
    }

    /// `count` tokens onto the battlefield, summoning sick like anything new.
    mutating func createTokens(_ template: PlaytestTokenTemplate, count: Int = 1) {
        guard count > 0 else { return }
        let item = CardItem(token: template)
        for _ in 0..<count {
            var token = PlaytestCard(card: item, isToken: true)
            enter(&token)
            battlefield.append(token)
        }
        record(.token, count == 1 ? "Created a \(template.name) token" : "Created \(count) \(template.name) tokens")
    }

    /// A token copy of a permanent.
    mutating func createTokenCopy(of id: UUID) {
        guard let original = battlefield.first(where: { $0.id == id }) else { return }
        var copy = original.tokenCopy()
        enter(&copy)
        battlefield.append(copy)
        record(.token, "Created a token copy of \(original.name)")
    }

    // MARK: Combat and life

    /// Untapped creatures that could be declared as attackers, sick ones
    /// included (something may have given them haste); defenders left out.
    var attackCandidates: [PlaytestCard] {
        battlefield.filter { $0.face.isCreature && !$0.isTapped && !$0.face.keywords.contains(.defender) }
    }

    func canAttack(_ card: PlaytestCard) -> Bool {
        card.face.isCreature && !card.isTapped && !card.face.keywords.contains(.defender) && !card.isSummoningSick(on: turn)
    }

    /// Declares attackers against the goldfish: each taps (vigilance
    /// aside) and deals its power (twice with double strike); lifelink
    /// gains it; a commander's damage is also counted as commander damage.
    @discardableResult
    mutating func attack(with ids: [UUID]) -> PlaytestAttackResult? {
        guard phase == .main else { return nil }
        var attackers = 0, damage = 0, gained = 0
        for id in ids {
            guard let i = battlefield.firstIndex(where: { $0.id == id }), battlefield[i].face.isCreature, !battlefield[i].isTapped else { continue }
            let card = battlefield[i]
            let keywords = card.face.keywords
            let dealt = max(0, card.power ?? 0) * (keywords.contains(.doubleStrike) ? 2 : 1)
            attackers += 1
            damage += dealt
            if keywords.contains(.lifelink) { gained += dealt }
            if !keywords.contains(.vigilance) { battlefield[i].isTapped = true }
            if card.isCommander, rules.commanderDamage { commanderDamage[id, default: 0] += dealt }
        }
        guard attackers > 0 else { return nil }
        opponentLife -= damage
        life += gained
        record(.combat, "Attacked with \(attackers) for \(damage)" + (gained > 0 ? ", gained \(gained) life" : "")
               + " · opponent at \(opponentLife)", notable: true)
        checkDefeat()
        return PlaytestAttackResult(attackers: attackers, damage: damage, lifeGained: gained)
    }

    mutating func adjustLife(_ delta: Int) {
        guard delta != 0 else { return }
        life += delta
        record(.life, "Life \(delta > 0 ? "+" : "")\(delta) · \(life)")
    }

    mutating func adjustOpponentLife(_ delta: Int) {
        guard delta != 0 else { return }
        opponentLife += delta
        record(.life, "Opponent \(delta > 0 ? "+" : "")\(delta) · \(opponentLife)")
        checkDefeat()
    }

    /// The most commander damage any one commander has dealt.
    var mostCommanderDamage: Int { commanderDamage.values.max() ?? 0 }

    private mutating func checkDefeat() {
        let defeated = opponentLife <= 0 || (rules.commanderDamage && mostCommanderDamage >= PlaytestRules.commanderDamageLimit)
        if defeated, defeatedOnTurn == nil {
            defeatedOnTurn = turn
            record(.combat, "Opponent defeated on turn \(turn)", notable: true)
        } else if !defeated {
            defeatedOnTurn = nil
        }
    }

    // MARK: Mana

    /// Untapped sources that make mana with {T} alone, minus creatures
    /// still summoning sick.
    func paySources() -> [PlaytestPaySource] {
        battlefield.compactMap { card in
            guard !card.isTapped, let mana = card.face.mana, !card.isSummoningSick(on: turn) else { return nil }
            return PlaytestPaySource(id: card.id, mana: mana, rank: card.face.isLand ? 0 : card.face.isCreature ? 2 : 1)
        }
    }

    /// Mana the untapped sources can make right now.
    var manaAvailable: Int { paySources().reduce(0) { $0 + $1.mana.units } }
    /// Mana the sources on the battlefield make, tapped or not — minus
    /// creatures still summoning sick, which can't tap for it this turn,
    /// so "Mana 1/1" is never "1/2" with nothing left to tap.
    var manaTotal: Int {
        battlefield.reduce(0) { $0 + ($1.isSummoningSick(on: turn) ? 0 : ($1.face.mana?.units ?? 0)) }
    }

    // MARK: Reading the table

    func zone(of id: UUID) -> PlaytestZone? {
        if hand.contains(where: { $0.id == id }) { return .hand }
        if battlefield.contains(where: { $0.id == id }) { return .battlefield }
        if library.contains(where: { $0.id == id }) { return .library }
        if graveyard.contains(where: { $0.id == id }) { return .graveyard }
        if exile.contains(where: { $0.id == id }) { return .exile }
        if command.contains(where: { $0.id == id }) { return .command }
        return nil
    }

    func card(_ id: UUID) -> PlaytestCard? {
        for zone in PlaytestZone.allCases {
            if let card = cards(in: zone).first(where: { $0.id == id }) { return card }
        }
        return nil
    }

    func cards(in zone: PlaytestZone) -> [PlaytestCard] {
        switch zone {
        case .library: return library
        case .hand: return hand
        case .battlefield: return battlefield
        case .graveyard: return graveyard
        case .exile: return exile
        case .command: return command
        }
    }

    private var allCards: [PlaytestCard] { library + hand + battlefield + graveyard + exile + command }

    private mutating func remove(_ id: UUID) -> PlaytestCard? {
        if let i = hand.firstIndex(where: { $0.id == id }) { return hand.remove(at: i) }
        if let i = battlefield.firstIndex(where: { $0.id == id }) { return battlefield.remove(at: i) }
        if let i = library.firstIndex(where: { $0.id == id }) { return library.remove(at: i) }
        if let i = graveyard.firstIndex(where: { $0.id == id }) { return graveyard.remove(at: i) }
        if let i = exile.firstIndex(where: { $0.id == id }) { return exile.remove(at: i) }
        if let i = command.firstIndex(where: { $0.id == id }) { return command.remove(at: i) }
        return nil
    }

    var landsOnBattlefield: [PlaytestCard] { battlefield.filter(\.isLand) }
    /// The battlefield by row, in play order within each.
    func battlefield(in row: PlaytestRow) -> [PlaytestCard] { battlefield.filter { $0.tableRow == row } }
    var untappedLands: Int { landsOnBattlefield.filter { !$0.isTapped }.count }

    /// A row's cards in piles: the same card in the same state (tapped,
    /// face, counters, sickness, token or not) shares one, in play order.
    func stacks(in row: PlaytestRow) -> [PlaytestStack] {
        var order: [String] = []
        var piles: [String: [PlaytestCard]] = [:]
        for card in battlefield(in: row) {
            let counters = card.counters.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)\($0.value)" }.joined()
            let key = [card.card.id, card.isToken ? "t" : "", card.isTapped ? "x" : "", card.showsBack ? "b" : "",
                       card.isSummoningSick(on: turn) ? "s" : "", card.isCommander ? "c" : "", counters].joined(separator: "|")
            if piles[key] == nil { order.append(key) }
            piles[key, default: []].append(card)
        }
        return order.map { PlaytestStack(cards: piles[$0] ?? []) }
    }

    // MARK: Log

    private mutating func record(_ kind: PlaytestEvent.Kind, _ text: String, notable: Bool = false) {
        log.append(PlaytestEvent(id: log.count, turn: turn, kind: kind, text: text, isNotable: notable))
    }

    private static func names(_ cards: [PlaytestCard]) -> String {
        let names = cards.map(\.name)
        switch names.count {
        case 0: return ""
        case 1...3: return names.joined(separator: ", ")
        default: return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        }
    }
}

/// Undo and redo over whole states: a game is small, and a state is a
/// value, so a step back is the state before.
nonisolated struct PlaytestHistory: Sendable {
    private(set) var past: [PlaytestState] = []
    private(set) var future: [PlaytestState] = []
    static let limit = 200

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    mutating func record(_ state: PlaytestState) {
        past.append(state)
        if past.count > Self.limit { past.removeFirst(past.count - Self.limit) }
        future = []
    }

    mutating func undo(from current: PlaytestState) -> PlaytestState? {
        guard let last = past.popLast() else { return nil }
        future.append(current)
        return last
    }

    mutating func redo(from current: PlaytestState) -> PlaytestState? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }

    mutating func clear() {
        past = []
        future = []
    }

    /// Applies a choice that isn't a step of the game (on the play or the
    /// draw) to every saved state, so neither Undo nor Redo takes it back.
    mutating func amend(_ change: (inout PlaytestState) -> Void) {
        for i in past.indices { change(&past[i]) }
        for i in future.indices { change(&future[i]) }
    }
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
