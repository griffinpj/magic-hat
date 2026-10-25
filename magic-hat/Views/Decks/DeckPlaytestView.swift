//
//  DeckPlaytestView.swift
//  magic-hat
//
//  Goldfishing a deck (see Playtest): a table laid out as one is, played
//  by Magic's turn structure.
//
//  Top to bottom: the opponent's side (their life, commander damage, the
//  turn they fell) with the command zone in its own slot at the top
//  right, out of the way of the thumbs; the battlefield, growing upwards
//  from the player — lands nearest, then the other permanents, creatures
//  in front — with identical cards in piles and the turn's two buttons,
//  Attack and End Turn, floating at its foot; a strip of the player's
//  zones (life, library, graveyard, exile, the mana their untapped
//  sources make); and the hand, fanned along the bottom edge (see
//  PlaytestHand).
//
//  The hand is played the way a card game's is: drag a card up onto the
//  battlefield and let go to play it — a land onto the battlefield (one a
//  turn; a second asks), a permanent spell onto the battlefield, an
//  instant or sorcery straight into the graveyard, with a toast saying
//  so; hold a card to see it large; tap it for its sheet (PlaytestInspector,
//  sliding up, swiped down to put away) with everything it can do. On the
//  battlefield a tap taps or untaps; a hold opens the sheet. The command
//  zone and the graveyard and exile lists open it too — never a cast on a
//  stray tap. Lands and mana sources are tapped to pay (Auto-Tap
//  Mana, in the menu). Every change is one value, undoable from the bar
//  or the toast.
//
//  Full screen from the deck's "…" menu and its Details page. Nothing
//  here writes anything: a game leaves no trace in the deck, History or
//  versions.
//
//  The deck is dealt once, off the main actor, from the first snapshot
//  the screen is given: the cover's closure runs again on every update of
//  the deck screen behind it, and dealing in `init` read every card's
//  text and shuffled on the main thread each time — while a later
//  snapshot (or none, mid-reload) would have re-dealt or blanked a game
//  in progress.
//
//  On a phone on its side the hand stays along the bottom under the
//  battlefield and everything else — the opponent, the command zone, the
//  zones and the mana — moves to a column beside it; stacked as in
//  portrait the battlefield was left about 60pt.
//

import SwiftUI

struct DeckPlaytestView: View {
    /// The deck to deal from; only the first one given is used.
    let snapshot: DeckSnapshot?

    /// Auto-Tap Mana, remembered between games.
    static let autoPayKey = "playtest.autoPay"

    @Environment(\.dismiss) private var dismiss
    @State private var game: PlaytestDeal?

    var body: some View {
        if let game {
            PlaytestTableScreen(deal: game)
        } else {
            NavigationStack {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground).ignoresSafeArea())
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    }
            }
            .task(id: snapshot?.id) { await deal() }
        }
    }

    private func deal() async {
        guard game == nil, let snapshot else { return }
        game = await Self.deal(snapshot)
    }

    /// Reads every card (types, keywords, mana — a few patterns each) and
    /// shuffles the first hand, on the global executor.
    @concurrent nonisolated private static func deal(_ snapshot: DeckSnapshot) async -> PlaytestDeal {
        var random = TableRandom()
        var state = PlaytestState(snapshot: snapshot)
        state.newGame(using: &random)
        return PlaytestDeal(snapshot: snapshot, state: state, rng: random)
    }
}

/// A dealt game: the deck it came from, the table, and the shuffle's
/// generator.
private nonisolated struct PlaytestDeal: Sendable {
    let snapshot: DeckSnapshot
    let state: PlaytestState
    let rng: TableRandom
}

private struct PlaytestTableScreen: View {
    let snapshot: DeckSnapshot

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(DeckPlaytestView.autoPayKey) private var autoPay = true
    @State private var state: PlaytestState
    @State private var history = PlaytestHistory()
    @State private var rng: TableRandom
    @State private var inspecting: InspectTarget?
    /// The inspector's content height, for its sheet's detent (the
    /// sheet adds the home indicator's inset itself). Estimated as a card
    /// is opened, then measured.
    @State private var inspectorHeight: CGFloat = 600
    /// The table's size: the inspector's card and its sheet's limit.
    @State private var tableSize = CGSize(width: 402, height: 874)
    /// The height under the navigation bar, down to the screen's foot:
    /// the room the hand's preview has above it.
    @State private var contentHeight: CGFloat = 780
    @State private var carrying: PlaytestCard?
    @State private var sheet: PlaytestSheetKind?
    @State private var pending: PendingPlay?
    @State private var toast: PlaytestToast?
    @State private var lifeTarget: LifeTarget?
    @State private var confirmNewGame = false
    @State private var showGuide = false
    @State private var feedback = 0
    @State private var drew = 0

    init(deal: PlaytestDeal) {
        snapshot = deal.snapshot
        _state = State(initialValue: deal.state)
        _rng = State(initialValue: deal.rng)
    }

    /// The table's cards grow with a wide table (an iPad) — 64pt on the
    /// battlefield and 100pt in hand are phone sizes — and shrink a little
    /// on a small phone or one on its side.
    private var scale: CGFloat { min(1.5, max(0.85, min(tableSize.width, tableSize.height) / 402)) }
    private var tableCardWidth: CGFloat { (64 * scale).rounded() }
    /// Never under 44pt: the commanders are tapped to open them.
    private var commandCardWidth: CGFloat { max(44, (44 * scale).rounded()) }
    private var handCardWidth: CGFloat { (PlaytestHand.defaultCardWidth * scale).rounded() }
    private var isSideways: Bool { verticalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            Group {
                if isSideways { sidewaysTable } else { uprightTable }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(title)
            .navigationSubtitle(snapshot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .overlay(alignment: .top) {
                if let toast {
                    PlaytestToastView(toast: toast) { undo() }
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .task(id: toast.id) {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation { self.toast = nil }
                        }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: drew)
            .sensoryFeedback(.selection, trigger: feedback)
            .sheet(item: $sheet) { kind in sheetContent(kind) }
            .sheet(item: $inspecting) { target in
                inspectorSheet(target.id)
                    .presentationDetents([.height(min(inspectorHeight, tableSize.height * 0.92))])
                    .presentationDragIndicator(.visible)
                    // Thick enough that the table's buttons don't show
                    // through the captions.
                    .presentationBackground(.thickMaterial)
            }
            .sheet(isPresented: $showGuide) { ToolGuideView(guide: Self.guide) }
            .alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                   presenting: pending) { pending in
                Button("Cancel", role: .cancel) {}
                Button(pending.confirmLabel) { perform(pending.cardID, pending.play, force: true) }
            } message: { pending in
                Text(pending.message)
            }
            .alert("Start a New Game?", isPresented: $confirmNewGame) {
                Button("New Game", role: .destructive) { newGame() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything goes back into the library, shuffled, and seven are drawn.")
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tableSize = $0 }
        .defersSystemGestures(on: .bottom)
    }

    private var title: String {
        switch state.phase {
        case .opening, .bottoming: return "Opening Hand"
        case .main: return "Turn \(state.turn)"
        case .cleanup: return "End of Turn \(state.turn)"
        }
    }

    // MARK: Layouts

    /// Upright: the opponent, the battlefield, the zones, the hand.
    private var uprightTable: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            tableArea
            Divider()
            zoneStrip
            hand
        }
    }

    /// On its side: the battlefield over the hand, and a column beside them
    /// for the opponent, the command zone, the zones and the mana.
    private var sidewaysTable: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                tableArea
                hand
            }
            Divider()
            sideColumn
        }
    }

    private var tableArea: some View {
        ZStack(alignment: .bottom) {
            battlefield
            if let carrying { dropZone(carrying) }
            if state.phase == .opening {
                // A short table scrolls the panel rather than clipping it.
                ViewThatFits(in: .vertical) {
                    openingPanel
                    ScrollView { openingPanel }.scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: .infinity)
            }
            boardControls
        }
    }

    private var hand: some View {
        PlaytestHand(cards: state.hand, mode: handMode,
                     onTap: tapInHand, onPlay: { attemptPlay($0.id, state.dragPlay($0.id, autoPay: autoPay)) },
                     armed: $carrying, cardWidth: handCardWidth,
                     previewMaxHeight: contentHeight - PlaytestHand.visibleHeight(cardWidth: handCardWidth))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("playtest-hand")
    }

    private var sideColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                opponent
                if state.hasCommanders { commandZone }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 4) {
                    zoneButtons
                }
                manaReadout
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 200)
    }

    // MARK: Top: the opponent and the command zone

    /// The other side of the table — what the goldfish has left — and the
    /// command zone in its own slot at the top right.
    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            opponent
            Spacer(minLength: 0)
            if state.hasCommanders { commandZone }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The opponent's life, commander damage and the turn they fell.
    private var opponent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label("Opponent", systemImage: "person.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                lifeButton(.opponent)
            }
            if state.rules.commanderDamage, state.mostCommanderDamage > 0 {
                Text("Commander damage \(state.mostCommanderDamage)/\(PlaytestRules.commanderDamageLimit)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("playtest-commander-damage")
            }
            if let turn = state.defeatedOnTurn {
                Label("Defeated on turn \(turn)", systemImage: "trophy.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("playtest-defeated")
            }
        }
    }

    /// The commanders, small, in a slot of their own. A tap opens the
    /// inspector (cast from there, with the tax shown) — never a cast.
    private var commandZone: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if state.command.isEmpty {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: commandCardWidth, height: commandCardWidth / (488.0 / 680.0))
                        .overlay { Image(systemName: "crown").foregroundStyle(.tertiary) }
                        .accessibilityLabel("Command zone, empty")
                }
                ForEach(state.command) { card in
                    PlaytestCardView(card: card, width: commandCardWidth)
                        .overlay(alignment: .bottom) {
                            if let tax = commanderTax(card), tax > 0 {
                                Text("+\(tax)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 4)
                                    .background(.orange, in: Capsule())
                                    .foregroundStyle(.white)
                                    .padding(2)
                            }
                        }
                        .onTapGesture { inspect(card.id) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(card.name), command zone" + ((commanderTax(card) ?? 0) > 0 ? ", tax \(commanderTax(card) ?? 0)" : ""))
                        .accessibilityHint("Opens the card.")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("playtest-command-\(card.name)")
                }
            }
            Text("Command")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playtest-command-zone")
    }

    private func commanderTax(_ card: PlaytestCard) -> Int? {
        state.commanderCasts[card.id].map { $0 * 2 }
    }

    // MARK: Battlefield

    /// Bottom-anchored: the rows stack up from the player, creatures on
    /// top, lands at the foot, clear of the buttons floating there. An
    /// empty table says what to do, low, where the first card will land.
    private var battlefield: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.battlefield.isEmpty {
                        Text(emptyHint)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .accessibilityIdentifier("playtest-empty")
                    } else {
                        ForEach(PlaytestRow.allCases) { row in
                            let stacks = state.stacks(in: row)
                            if !stacks.isEmpty { tableRow(row, stacks) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 70)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottomLeading)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(state.phase == .opening ? 0 : 1)
        .accessibilityIdentifier("playtest-battlefield")
    }

    private var emptyHint: String {
        switch state.phase {
        case .opening: return ""
        case .bottoming: return "Choose the cards to put on the bottom."
        case .cleanup: return "Discard down to \(state.rules.handSize)."
        case .main: return state.hand.isEmpty ? "Draw to begin." : "Drag a card up from your hand to play it.\nHold one to see it; tap for more."
        }
    }

    private func tableRow(_ row: PlaytestRow, _ stacks: [PlaytestStack]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tableCardWidth + 8), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(stacks) { stack in
                    PlaytestCardView(card: stack.top, width: tableCardWidth, turn: state.turn, onTable: true, pileCount: stack.count)
                        .onTapGesture { tapOnTable(stack) }
                        .onLongPressGesture(minimumDuration: 0.35) { inspect(stack.actionCard.id) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(PlaytestSpeech.label(stack.top, turn: state.turn, count: stack.count))
                        .accessibilityHint("Tap to \(stack.top.isTapped ? "untap" : "tap"). Hold for more.")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "More") { inspect(stack.actionCard.id) }
                        .accessibilityIdentifier("playtest-battlefield-\(stack.top.name)")
                }
            }
            Text("\(row.label) · \(stacks.reduce(0) { $0 + $1.count })" + (row == .lands ? " · \(state.untappedLands) untapped" : ""))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
        }
    }

    /// The battlefield lit up while a card from hand is carried over it.
    /// It names the face the drop plays (`dragPlay`: a modal card's land
    /// back while the land drop is ready).
    private func dropZone(_ card: PlaytestCard) -> some View {
        let play = state.dragPlay(card.id, autoPay: autoPay)
        let face = state.face(card.id, for: play) ?? card.info.front
        let verb = face.isLand ? "play" : "cast"
        var notes: [String] = []
        if play == .back { notes.append("The other face of \(card.info.front.name)") }
        switch state.issue(playing: card.id, as: play, autoPay: autoPay) {
        case .landAlreadyPlayed: notes.append("You’ve played a land this turn")
        case .cannotPay: notes.append("Not enough mana — you’ll be asked")
        default: if !face.isPermanent { notes.append("It resolves into the graveyard") }
        }
        let note: String? = notes.isEmpty ? nil : notes.joined(separator: " · ")
        return RoundedRectangle(cornerRadius: 22)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))
            // At the top, clear of the finger and the card it carries.
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    Text("Release to \(verb) \(face.name)").font(.headline)
                    if let note { Text(note).font(.subheadline).foregroundStyle(.secondary) }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                .padding(.top, 20)
                .padding(.horizontal, 12)
            }
            .padding(10)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityIdentifier("playtest-drop-zone")
    }

    /// What floats at the foot of the battlefield: the turn's buttons, or
    /// the banner while cards are chosen.
    @ViewBuilder private var boardControls: some View {
        switch state.phase {
        case .bottoming(let n):
            PlaytestBanner(text: n == 1 ? "Tap 1 card to put on the bottom" : "Tap \(n) cards to put on the bottom",
                           systemImage: "arrow.down.to.line")
                .padding(.bottom, 12)
                .accessibilityIdentifier("playtest-bottom-banner")
        case .cleanup(let n):
            PlaytestBanner(text: "Hand size is \(state.rules.handSize): discard \(n)", systemImage: "minus.circle", tint: .red)
                .padding(.bottom, 12)
                .accessibilityIdentifier("playtest-discard-banner")
        case .main:
            HStack(spacing: 10) {
                Spacer()
                Button("Attack", systemImage: "bolt") { sheet = .attack }
                    .buttonStyle(.glass)
                    .disabled(state.attackCandidates.isEmpty)
                    .accessibilityIdentifier("playtest-attack")
                Button("End Turn", systemImage: "arrow.right.circle") {
                    act { $0.endTurn() }
                    drew += 1
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("playtest-end-turn")
            }
            .controlSize(.large)
            .lineLimit(1)
            .padding(12)
            .opacity(carrying == nil ? 1 : 0)
        case .opening:
            EmptyView()
        }
    }

    // MARK: Opening hand

    /// Before turn one: the hand's shape, what a mulligan costs here,
    /// (two-player formats) play or draw, and the choice itself.
    private var openingPanel: some View {
        let lands = state.hand.filter { $0.info.front.isLand }.count
        return VStack(spacing: 12) {
            Text(state.mulligans == 0 ? "Opening Hand" : "Mulligan \(state.mulligans)")
                .font(.headline)
            Text("\(state.hand.count) cards · \(lands) \(lands == 1 ? "land" : "lands") · \(state.hand.count - lands) spells")
                .font(.subheadline)
                .monospacedDigit()
                .accessibilityIdentifier("playtest-opening-summary")
            Text(mulliganNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !state.rules.isMultiplayer {
                Picker("Turn order", selection: Binding(get: { state.onThePlay }, set: { setOnThePlay($0) })) {
                    Text("On the Play").tag(true)
                    Text("On the Draw").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("playtest-play-draw")
            }
            HStack(spacing: 10) {
                Button("Mulligan", systemImage: "arrow.triangle.2.circlepath") {
                    act { $0.mulligan(using: &rng) }
                    drew += 1
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("playtest-mulligan")
                Button(state.cardsToBottom > 0 ? "Keep \(state.keepSize)" : "Keep \(state.hand.count)", systemImage: "checkmark") {
                    act { $0.keep() }
                    drew += 1
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("playtest-keep")
            }
            .controlSize(.large)
            .padding(.top, 4)
            Text("Hold a card to see it; tap it for more.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playtest-opening")
    }

    private var mulliganNote: String {
        var lines: [String] = []
        if state.cardsToBottom > 0 {
            lines.append("Keeping puts \(state.cardsToBottom) \(state.cardsToBottom == 1 ? "card" : "cards") on the bottom.")
        } else if state.mulligans == 0 {
            lines.append(state.rules.freeMulligan
                         ? "Your first mulligan is free: seven again, nothing to the bottom."
                         : "A mulligan shuffles and draws seven again, then puts one on the bottom per mulligan.")
        }
        if state.rules.isMultiplayer {
            lines.append("In multiplayer everyone draws on turn one.")
        } else {
            lines.append(state.onThePlay ? "On the play you skip your first draw." : "On the draw you draw on turn one.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: Zones

    /// The zones in a 44pt strip: each chip's target is the strip's
    /// height (PlaytestChipStyle).
    private var zoneStrip: some View {
        HStack(spacing: 4) {
            zoneButtons
            Spacer(minLength: 0)
            manaReadout
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var zoneButtons: some View {
        lifeButton(.you)
        libraryMenu
        zoneButton(.graveyard, systemImage: "archivebox", count: state.graveyard.count)
        zoneButton(.exile, systemImage: "xmark.bin", count: state.exile.count)
    }

    /// "Mana 2/3": what the untapped sources make, of what every source
    /// able to tap this turn makes.
    private var manaReadout: some View {
        VStack(alignment: isSideways ? .leading : .trailing, spacing: 0) {
            Text("Mana \(state.manaAvailable)/\(state.manaTotal)")
                .font(.subheadline.weight(.semibold))
                .contentTransition(.numericText())
            if state.phase.isPlaying {
                Text(state.landsPlayed == 0 ? "Land drop ready" : "Land played")
                    .font(.caption2)
                    .foregroundStyle(state.landsPlayed == 0 ? .green : .secondary)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mana, \(state.manaAvailable) of \(state.manaTotal) available" + (state.phase.isPlaying ? (state.landsPlayed == 0 ? ", land drop ready" : ", land played") : ""))
        .accessibilityIdentifier("playtest-mana")
    }

    private func lifeButton(_ target: LifeTarget) -> some View {
        let life = target == .you ? state.life : state.opponentLife
        return Button {
            lifeTarget = target
        } label: {
            Label("\(life)", systemImage: "heart.fill")
                .fontWeight(.semibold)
                .contentTransition(.numericText(value: Double(life)))
        }
        .buttonStyle(PlaytestChipStyle(tint: target == .you ? .red : .secondary))
        .accessibilityLabel(target == .you ? "Your life, \(life)" : "Opponent's life, \(life)")
        .accessibilityIdentifier(target == .you ? "playtest-life" : "playtest-opponent-life")
        .popover(isPresented: Binding(get: { lifeTarget == target }, set: { if !$0 { lifeTarget = nil } })) {
            PlaytestLifeAdjuster(
                title: target == .you ? "Your Life" : "Opponent’s Life",
                life: target == .you ? state.life : state.opponentLife,
                detail: target == .opponent && state.rules.commanderDamage && state.mostCommanderDamage > 0
                    ? "Commander damage \(state.mostCommanderDamage) of \(PlaytestRules.commanderDamageLimit)" : nil
            ) { delta in
                act(.snappy) { s in if target == .you { s.adjustLife(delta) } else { s.adjustOpponentLife(delta) } }
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private var libraryMenu: some View {
        Menu {
            Button("Draw", systemImage: "plus.rectangle.on.rectangle") { draw(1) }
            Menu("Draw Several", systemImage: "rectangle.stack") {
                ForEach([2, 3, 7], id: \.self) { n in Button("Draw \(n)") { draw(n) } }
            }
            Divider()
            Menu("Scry", systemImage: "eye") {
                ForEach([1, 2, 3, 4], id: \.self) { n in Button("Scry \(n)") { sheet = .top(.scry, n) } }
            }
            Menu("Surveil", systemImage: "eye.trianglebadge.exclamationmark") {
                ForEach([1, 2, 3], id: \.self) { n in Button("Surveil \(n)") { sheet = .top(.surveil, n) } }
            }
            Menu("Look at the Top", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                ForEach([1, 3, 5, 7, 10], id: \.self) { n in Button("Top \(n)") { sheet = .top(.look, n) } }
            }
            Menu("Mill", systemImage: "archivebox") {
                ForEach([1, 2, 3, 5, 10], id: \.self) { n in Button("Mill \(n)") { act { $0.mill(n) } } }
            }
            Divider()
            Button("Search Library…", systemImage: "magnifyingglass") { sheet = .search }
            Button("Shuffle", systemImage: "shuffle") { act { $0.shuffle(using: &rng) }; feedback += 1 }
        } label: {
            Label("\(state.librarySize)", systemImage: "rectangle.stack")
                .fontWeight(.semibold)
                .contentTransition(.numericText(value: Double(state.librarySize)))
        }
        .menuStyle(.button)
        .buttonStyle(PlaytestChipStyle())
        .disabled(state.phase != .main || state.librarySize == 0)
        .accessibilityLabel("Library, \(state.librarySize)")
        .accessibilityIdentifier("playtest-library")
    }

    private func zoneButton(_ zone: PlaytestZone, systemImage: String, count: Int) -> some View {
        Button {
            sheet = .zone(zone)
        } label: {
            Label("\(count)", systemImage: systemImage)
                .fontWeight(.semibold)
                .contentTransition(.numericText(value: Double(count)))
        }
        .buttonStyle(PlaytestChipStyle())
        .disabled(count == 0)
        .accessibilityLabel("\(zone.label), \(count) cards")
        .accessibilityIdentifier("playtest-\(zone.rawValue)")
    }

    // MARK: Hand

    private var handMode: PlaytestHandMode {
        switch state.phase {
        case .opening: return .looking
        case .main: return .playing
        case .bottoming: return .choosing(systemImage: "arrow.down.to.line.circle.fill", tint: .orange)
        case .cleanup: return .choosing(systemImage: "minus.circle.fill", tint: .red)
        }
    }

    // MARK: Taps

    private func tapInHand(_ card: PlaytestCard) {
        switch state.phase {
        case .opening, .main:
            inspect(card.id)
        case .bottoming:
            act { $0.bottom(card.id) }
            feedback += 1
        case .cleanup:
            act { $0.discard(card.id) }
            feedback += 1
        }
    }

    private func tapOnTable(_ stack: PlaytestStack) {
        act(.snappy(duration: 0.22)) { $0.toggleTap(stack.actionCard.id) }
        feedback += 1
    }

    /// Play or draw is a choice about the game, not a step in it: no undo
    /// step, and every saved state takes it, so Undo doesn't flip it back.
    private func setOnThePlay(_ value: Bool) {
        history.amend { $0.setOnThePlay(value) }
        state.setOnThePlay(value)
        feedback += 1
    }

    /// Opens the card's sheet at the height it will roughly need, rather
    /// than the last card's, which it then animated away from.
    private func inspect(_ id: UUID) {
        inspectorHeight = PlaytestInspector.estimatedHeight(
            options: state.options(for: id, autoPay: autoPay),
            counters: state.zone(of: id) == .battlefield ? state.counterKinds(for: id).count : 0,
            cardWidth: inspectorCardWidth)
        inspecting = InspectTarget(id: id)
        feedback += 1
    }

    /// The inspector's card: a third of the table's height at most.
    private var inspectorCardWidth: CGFloat {
        min(tableSize.width - 120, 250, tableSize.height * 0.36 * (488.0 / 680.0))
    }

    /// Plays at once when nothing stands in the way; asks when the land
    /// drop is used or the sources can't pay.
    private func attemptPlay(_ id: UUID, _ play: PlaytestPlay) {
        switch state.issue(playing: id, as: play, autoPay: autoPay) {
        case nil:
            perform(id, play, force: false)
        case .landAlreadyPlayed:
            pending = PendingPlay(cardID: id, play: play, title: "Already Played a Land",
                                  message: "You get one land a turn. Play another only if an effect lets you.",
                                  confirmLabel: "Play Land Anyway")
        case .cannotPay(let cost, let available):
            let name = state.face(id, for: play)?.name ?? "It"
            pending = PendingPlay(cardID: id, play: play, title: "Not Enough Mana",
                                  message: "\(name) costs \(ManaText.plain(cost)); your untapped sources make \(available). Cast it anyway and tap for it yourself?",
                                  confirmLabel: "Cast Anyway")
        case .notMainPhase, .notAPermanent:
            break
        }
    }

    private func perform(_ id: UUID, _ play: PlaytestPlay, force: Bool) {
        act { $0.play(id, as: play, autoPay: autoPay, force: force, using: &rng) }
        drew += 1
    }

    // MARK: Inspector

    /// The card's sheet. Its card is sized from the table (a third of its
    /// height at most), never from the sheet, whose height follows it.
    @ViewBuilder private func inspectorSheet(_ id: UUID) -> some View {
        if let card = state.card(id) {
            PlaytestInspector(
                card: card,
                whereabouts: state.whereabouts(of: id),
                options: state.options(for: id, autoPay: autoPay),
                counters: state.zone(of: id) == .battlefield ? state.counterKinds(for: id).map { ($0, card.counters[$0] ?? 0) } : [],
                cardWidth: inspectorCardWidth,
                onOption: { option in
                    act { $0.apply(option.command, to: id, autoPay: autoPay, using: &rng) }
                    feedback += 1
                },
                onCounter: { kind, delta in
                    act(.snappy) { $0.addCounters(kind, delta, to: id) }
                    feedback += 1
                },
                onHeight: { inspectorHeight = $0 },
                onClose: { inspecting = nil }
            )
        } else {
            // A token that ceased to exist while its sheet was up.
            Color.clear.onAppear { inspecting = nil }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
                .accessibilityIdentifier("playtest-done")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Undo", systemImage: "arrow.uturn.backward") { undo() }
                .disabled(!history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("playtest-undo")
            Menu {
                Button("Redo", systemImage: "arrow.uturn.forward") { redo() }
                    .disabled(!history.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("New Game", systemImage: "arrow.counterclockwise") { confirmNewGame = true }
                Button("Create Token…", systemImage: "circle.hexagongrid") { sheet = .tokens }
                    .disabled(state.phase != .main)
                Button("Untap All", systemImage: "arrow.clockwise") { act { $0.untapAll() } }
                    .disabled(state.battlefield.allSatisfy { !$0.isTapped })
                Toggle(isOn: $autoPay) {
                    Label("Auto-Tap Mana", systemImage: "bolt.badge.automatic")
                }
                Divider()
                Button("Game Log", systemImage: "list.bullet.rectangle") { sheet = .log }
                Button("How the Table Plays", systemImage: "info.circle") { showGuide = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("playtest-menu")
        }
    }

    // MARK: Sheets

    @ViewBuilder private func sheetContent(_ kind: PlaytestSheetKind) -> some View {
        switch kind {
        case .zone(let zone):
            PlaytestZoneSheet(zone: zone, cards: state.cards(in: zone)) { id in afterSheet { inspect(id) } }
                .presentationDetents([.medium, .large])
        case .top(let look, let n):
            PlaytestTopSheet(look: look, cards: state.top(n)) { placements in
                act { $0.arrangeTop(placements, as: look) }
            }
            .presentationDetents([.medium, .large])
        case .search:
            PlaytestSearchSheet(cards: state.library) { id, destination in
                act { $0.search(take: id, to: destination, using: &rng) }
            }
        case .tokens:
            PlaytestTokenSheet(deckTokens: snapshot.tokens.map(PlaytestTokenTemplate.init)) { template, count in
                act { $0.createTokens(template, count: count) }
            }
            .presentationDetents([.medium, .large])
        case .attack:
            PlaytestAttackSheet(candidates: state.attackCandidates, turn: state.turn, opponentLife: state.opponentLife) { ids in
                act { $0.attack(with: ids) }
                drew += 1
            }
            .presentationDetents([.medium, .large])
        case .log:
            PlaytestLogSheet(log: state.log)
        }
    }

    // MARK: State changes

    /// Every change goes through here: one undo step, the animation, and a
    /// toast when something happened that the tap didn't show.
    private func act(_ animation: Animation? = .snappy(duration: 0.25), _ change: (inout PlaytestState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        let seen = state.log.count
        history.record(state)
        // Under Reduce Motion cards jump to their places (a tapped card
        // turns without sweeping through 90°) and the toast fades.
        withAnimation(reduceMotion ? nil : animation) { state = next }
        if let event = next.log.dropFirst(seen).last(where: \.isNotable) {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy) { toast = PlaytestToast(text: event.text, kind: event.kind) }
        }
    }

    /// Closes the sheet, then does what would present something else: an
    /// alert or a cover presented while a sheet is still going away is
    /// dropped.
    private func afterSheet(_ action: @escaping () -> Void) {
        sheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }

    private func draw(_ n: Int) {
        act { $0.draw(n) }
        drew += 1
    }

    private func undo() {
        guard let previous = history.undo(from: state) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            state = previous
            toast = nil
        }
        feedback += 1
    }

    private func redo() {
        guard let next = history.redo(from: state) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { state = next }
        feedback += 1
    }

    private func newGame() {
        act { $0.newGame(using: &rng) }
        history.clear()
        toast = nil
        drew += 1
    }

    // MARK: Guide

    static let guide = ToolGuide(
        title: "How the Table Plays",
        sections: [
            .init(title: "A Turn", rows: [
                .init(icon: "hand.raised", title: "Opening hand",
                      text: "Keep or mulligan before turn one. A London mulligan shuffles and draws seven again; keeping then puts one card on the bottom per mulligan. In Commander, Oathbreaker and Brawl the first mulligan is free."),
                .init(icon: "rectangle.stack", title: "The first draw",
                      text: "In a two-player game whoever plays first skips their first draw — choose On the Play or On the Draw with the opening hand. In multiplayer formats everyone draws."),
                .init(icon: "arrow.right.circle", title: "Each turn",
                      text: "Your permanents untap, you draw, and you may play one land. End Turn discards down to seven, unless something gives you no maximum hand size."),
            ]),
            .init(title: "Playing Cards", rows: [
                .init(icon: "mountain.2", title: "Lands are played, not cast",
                      text: "One a turn; a second asks first, for the effects that allow more. A land that enters tapped does."),
                .init(icon: "wand.and.stars", title: "Spells resolve where they belong",
                      text: "Creatures, artifacts, enchantments, planeswalkers and battles go onto the battlefield. Instants and sorceries go to the graveyard and never become permanents — exiled if cast with flashback, sent on an adventure (to exile, castable from there), and an Oathbreaker’s signature spell returns to the command zone."),
                .init(icon: "bolt.badge.automatic", title: "Paying for them",
                      text: "With Auto-Tap Mana on, casting taps lands and other {T}: Add sources — the least flexible first, so duals stay up — and summoning-sick creatures are left alone. A commander costs {2} more each time it was cast from the command zone. When the sources can’t pay, it asks; X is paid as 0, so tap the rest yourself."),
                .init(icon: "rectangle.on.rectangle", title: "Two-faced and split cards",
                      text: "Hold a card for its other face: the back of a modal double-faced card, the other half of a split card, the Adventure. A transforming card turns over on the battlefield."),
            ]),
            .init(title: "On the Battlefield", rows: [
                .init(icon: "zzz", title: "Summoning sickness",
                      text: "A creature that arrived this turn can’t attack or tap for mana unless it has haste."),
                .init(icon: "bolt", title: "Attacking",
                      text: "Attack taps the creatures you choose (vigilance doesn’t) and takes their power off the opponent’s life — double strike twice, lifelink back to you. In Commander, 21 damage from one commander also defeats them."),
                .init(icon: "circle.hexagongrid", title: "Tokens and counters",
                      text: "A token that leaves the battlefield ceases to exist. +1/+1 and −1/−1 counters cancel out; a creature with 0 toughness or a planeswalker with no loyalty goes to the graveyard."),
            ]),
            .init(title: "What It Leaves to You", rows: [
                .init(icon: "person.fill", title: "No opponent, no stack",
                      text: "Spells resolve as they are cast and nothing responds. Triggered and activated abilities aren’t automated: draw, search, scry, make tokens and move cards from the menus as the card says. Every step can be undone."),
            ]),
        ],
        source: nil
    )
}

// MARK: - Supporting types

private enum LifeTarget: Hashable { case you, opponent }

private struct InspectTarget: Identifiable, Hashable {
    let id: UUID
}

private enum PlaytestSheetKind: Identifiable, Hashable {
    case zone(PlaytestZone)
    case top(PlaytestLook, Int)
    case search, tokens, attack, log

    var id: String {
        switch self {
        case .zone(let zone): return "zone-\(zone.rawValue)"
        case .top(let look, let n): return "top-\(look)-\(n)"
        case .search: return "search"
        case .tokens: return "tokens"
        case .attack: return "attack"
        case .log: return "log"
        }
    }
}

private struct PendingPlay: Identifiable {
    let id = UUID()
    let cardID: UUID
    let play: PlaytestPlay
    let title: String
    let message: String
    let confirmLabel: String
}

/// The table's randomness: the system's, or under a seeded UI test run a
/// fixed seed, so a test's opening hand is the same every launch.
private nonisolated struct TableRandom: RandomNumberGenerator, Sendable {
    private var seeded: SeededGenerator? = UITestSeed.isSeededRun ? SeededGenerator(seed: 0x5EED_7AB1E) : nil
    private var system = SystemRandomNumberGenerator()

    mutating func next() -> UInt64 {
        if seeded != nil { return seeded!.next() }
        return system.next()
    }
}
