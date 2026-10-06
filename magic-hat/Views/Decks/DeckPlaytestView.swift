//
//  DeckPlaytestView.swift
//  magic-hat
//
//  The table (see Playtest), laid out as a table is: the hand along the
//  bottom with the command zone beside it, and above it the battlefield
//  growing *upwards* from the hand — lands nearest the player, artifacts
//  and enchantments above them, creatures on top — each row wrapping and
//  the whole anchored to the bottom, so the first land lands where the
//  hand can reach it and the empty space is at the top, out of the way.
//  A status line between them — turn, library, untapped lands, graveyard
//  and exile (tap either to look through it). One bar of actions: Draw,
//  Mulligan, Next Turn; New Game, Untap All and Shuffle in the menu.
//
//  Gestures are the ones a hand makes with real cards: tap a card in hand
//  to play it, tap a card on the battlefield to tap or untap it, hold any
//  card for everywhere else it could go (graveyard, exile, hand, the top
//  or bottom of the library, the command zone for a commander) and to
//  look at it, which opens the viewer on the card. Cards are drawn big
//  enough to hit (72pt on the table, 96pt in hand — Apple's 44pt minimum
//  with room to spare) and a tapped card turns in place. A London
//  mulligan draws seven and then asks for the cards to put on the bottom:
//  tap them in hand, with a banner counting down. Everything is one
//  `PlaytestState` value in `@State`; every move is a mutation of it, so
//  the screen can never disagree with the count.
//
//  Full screen from the deck's "…" menu and its Details page. Nothing
//  here writes anything: a game leaves no trace in the deck, History or
//  versions.
//

import SwiftUI

struct DeckPlaytestView: View {
    let snapshot: DeckSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var state: PlaytestState
    @State private var viewing: CardItem?
    @State private var browsing: PlaytestZone?
    @State private var confirmNewGame = false
    @State private var drew = 0
    @State private var tapped = 0

    private static let tableCardWidth: CGFloat = 72
    private static let handCardWidth: CGFloat = 96

    init(snapshot: DeckSnapshot) {
        self.snapshot = snapshot
        var fresh = PlaytestState(snapshot: snapshot)
        fresh.newGame()
        _state = State(initialValue: fresh)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                battlefield
                Divider()
                statusLine
                Divider()
                handAndCommand
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Playtest")
            .navigationSubtitle(snapshot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaBar(edge: .bottom) { actionBar }
            .sensoryFeedback(.impact(weight: .light), trigger: drew)
            .sensoryFeedback(.selection, trigger: tapped)
            .fullScreenCover(item: $viewing) { card in
                CardViewerView(items: CardItemList([card]), currentID: .constant(card.id), showsDetail: true)
            }
            .sheet(item: $browsing) { zone in
                ZoneSheet(title: zone.label, cards: cards(in: zone), onMove: { id, to in state.move(id, to: to) },
                          onView: { viewing = $0 })
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Start a new game?", isPresented: $confirmNewGame, titleVisibility: .visible) {
                Button("New Game", role: .destructive) { withAnimation { state.newGame() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything goes back to the library, shuffled, and seven are drawn.")
            }
        }
    }

    // MARK: Battlefield

    /// Bottom-anchored: the rows stack up from the hand, creatures on top,
    /// lands at the foot. An empty table says what to do, low, where the
    /// first card will land.
    private var battlefield: some View {
        GeometryReader { geo in
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if state.battlefield.isEmpty {
                    Text(state.hand.isEmpty ? "Draw to begin." : "Tap a card in hand to play it. Hold a card for more.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityIdentifier("playtest-empty")
                } else {
                    ForEach(PlaytestRow.allCases) { row in
                        let cards = state.battlefield(in: row)
                        if !cards.isEmpty { zoneRow(row.label, cards) }
                    }
                }
            }
            .padding(16)
            // At least the viewport tall, bottom-aligned: a short table
            // sits at the foot, a tall one scrolls and opens at the foot.
            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottomLeading)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("playtest-battlefield")
    }

    private func zoneRow(_ title: String, _ cards: [PlaytestCard]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tableCardWidth), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(cards) { card in
                    TableCard(card: card, width: Self.tableCardWidth)
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.22)) { state.toggleTap(card.id) }
                            tapped &+= 1
                        }
                        .contextMenu { cardMenu(card) }
                        .accessibilityLabel("\(card.card.name)\(card.isTapped ? ", tapped" : "")")
                        .accessibilityHint("Tap to \(card.isTapped ? "untap" : "tap"). Hold for more.")
                        .accessibilityIdentifier("playtest-battlefield-\(card.card.name)")
                }
            }
            Text("\(title) · \(cards.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }

    // MARK: Status

    private var statusLine: some View {
        HStack(spacing: 14) {
            stat("Turn", "\(state.turn)")
            stat("Library", "\(state.librarySize)")
            stat("Mana", "\(state.untappedLands)")
            Spacer()
            zoneButton(.graveyard, count: state.graveyard.count)
            zoneButton(.exile, count: state.exile.count)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .font(.subheadline)
        .monospacedDigit()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playtest-stat-\(label)")
    }

    private func zoneButton(_ zone: PlaytestZone, count: Int) -> some View {
        Button {
            browsing = zone
        } label: {
            HStack(spacing: 4) {
                Image(systemName: zone == .graveyard ? "archivebox" : "xmark.bin")
                Text("\(count)").fontWeight(.semibold)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(count == 0)
        .accessibilityLabel("\(zone.label), \(count) cards")
        .accessibilityIdentifier("playtest-\(zone.rawValue)")
    }

    // MARK: Hand

    private var handAndCommand: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if !state.command.isEmpty {
                commandZone
                Divider().frame(height: Self.handCardWidth / (488.0 / 680.0))
            }
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(state.hand) { card in
                        TableCard(card: card, width: Self.handCardWidth)
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.25)) {
                                    if state.pendingBottom > 0 { state.bottom(card.id) } else { state.play(card.id) }
                                }
                                tapped &+= 1
                            }
                            .contextMenu { cardMenu(card) }
                            .accessibilityLabel(card.card.name)
                            .accessibilityHint(state.pendingBottom > 0 ? "Tap to put on the bottom of the library" : "Tap to play. Hold for more.")
                            .accessibilityIdentifier("playtest-hand-\(card.card.name)")
                    }
                    if state.hand.isEmpty {
                        Text("No cards in hand")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(height: Self.handCardWidth / (488.0 / 680.0))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: Self.handCardWidth / (488.0 / 680.0) + 28)
        .accessibilityIdentifier("playtest-hand")
    }

    private var commandZone: some View {
        VStack(spacing: 4) {
            ForEach(state.command) { card in
                TableCard(card: card, width: Self.tableCardWidth)
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.25)) { state.play(card.id) }
                        tapped &+= 1
                    }
                    .contextMenu { cardMenu(card) }
                    .accessibilityLabel("\(card.card.name), command zone")
                    .accessibilityHint("Tap to cast. Hold for more.")
                    .accessibilityIdentifier("playtest-command-\(card.card.name)")
            }
            Text("Command")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var mulliganBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line")
            Text(state.pendingBottom == 1 ? "Tap 1 card in hand to put on the bottom"
                 : "Tap \(state.pendingBottom) cards in hand to put on the bottom")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.35)), in: Capsule())
        .accessibilityIdentifier("playtest-bottom-banner")
    }

    // MARK: Menus and actions

    @ViewBuilder private func cardMenu(_ card: PlaytestCard) -> some View {
        let zone = state.zone(of: card.id)
        Button("View Card", systemImage: "eye") { viewing = card.card }
        Divider()
        if zone == .battlefield {
            Button(card.isTapped ? "Untap" : "Tap", systemImage: "arrow.clockwise") { withAnimation { state.toggleTap(card.id) } }
        } else {
            Button("Play", systemImage: "arrow.up.right") { withAnimation { state.play(card.id) } }
        }
        if zone != .hand { Button("To Hand", systemImage: "hand.raised") { withAnimation { state.move(card.id, to: .hand) } } }
        if zone != .graveyard { Button("To Graveyard", systemImage: "archivebox") { withAnimation { state.move(card.id, to: .graveyard) } } }
        if zone != .exile { Button("Exile", systemImage: "xmark.bin") { withAnimation { state.move(card.id, to: .exile) } } }
        Menu("To Library", systemImage: "rectangle.stack") {
            Button("Top of Library", systemImage: "arrow.up.to.line") { withAnimation { state.move(card.id, to: .library, libraryEnd: .top) } }
            Button("Bottom of Library", systemImage: "arrow.down.to.line") { withAnimation { state.move(card.id, to: .library, libraryEnd: .bottom) } }
        }
        if card.isCommander, zone != .command {
            Button("To Command Zone", systemImage: "crown") { withAnimation { state.move(card.id, to: .command) } }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
                .accessibilityIdentifier("playtest-done")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Game", systemImage: "arrow.counterclockwise") { confirmNewGame = true }
                Button("Untap All", systemImage: "arrow.clockwise") { withAnimation { state.untapAll() } }
                    .disabled(state.battlefield.allSatisfy { !$0.isTapped })
                Button("Shuffle Library", systemImage: "shuffle") { state.shuffle() }
                Button("Draw 7", systemImage: "rectangle.stack") { withAnimation { drew += state.draw(7) } }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("playtest-menu")
        }
    }

    /// Labelled, not a toolbar's icons: at a table the three verbs have
    /// to read at a glance.
    private var actionBar: some View {
        VStack(spacing: 8) {
            if state.pendingBottom > 0 { mulliganBanner }
            HStack(spacing: 10) {
                Button("Draw", systemImage: "plus.rectangle.on.rectangle") { withAnimation { drew += state.draw() } }
                    .disabled(state.librarySize == 0)
                    .fixedSize()
                    .accessibilityIdentifier("playtest-draw")
                Button("Mulligan", systemImage: "arrow.triangle.2.circlepath") { withAnimation { state.mulligan() } }
                    .disabled(state.turn > 1 || state.pendingBottom > 0)
                    .fixedSize()
                    .accessibilityIdentifier("playtest-mulligan")
                Spacer()
                Button("Next Turn", systemImage: "arrow.right.circle") { withAnimation { state.nextTurn(); drew += 1 } }
                    .disabled(state.pendingBottom > 0)
                    .fixedSize()
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("playtest-next-turn")
            }
            .buttonStyle(.glass)
            .lineLimit(1)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }

    private func cards(in zone: PlaytestZone) -> [PlaytestCard] {
        switch zone {
        case .library: return state.library
        case .hand: return state.hand
        case .battlefield: return state.battlefield
        case .graveyard: return state.graveyard
        case .exile: return state.exile
        case .command: return state.command
        }
    }
}

/// A card on the table: its image, turned on its side when tapped, with
/// its name as a label when there is no image yet. The whole slot is the
/// hit area, tapped or not.
private struct TableCard: View {
    let card: PlaytestCard
    let width: CGFloat

    var body: some View {
        let aspect = card.card.aspectRatio
        CardImageView(urlString: card.card.displayImageURL, aspectRatio: aspect, cornerRadius: 5, targetWidth: width * 2)
            .overlay {
                if card.card.imageURL == nil {
                    Text(card.card.name)
                        .font(.system(size: 10, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(4)
                }
            }
            .frame(width: width)
            .rotationEffect(.degrees(card.isTapped ? 90 : 0))
            .scaleEffect(card.isTapped ? aspect : 1)
            .frame(width: width, height: width / aspect)
            .opacity(card.isTapped ? 0.78 : 1)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
            .contentShape(Rectangle())
    }
}

/// A zone's cards as a list — graveyard or exile — each with the moves
/// back out of it; a tap on the row opens the card in the viewer.
private struct ZoneSheet: View {
    let title: String
    let cards: [PlaytestCard]
    let onMove: (UUID, PlaytestZone) -> Void
    let onView: (CardItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if cards.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                }
                ForEach(cards.reversed()) { card in
                    HStack(spacing: 12) {
                        Button {
                            onView(card.card)
                        } label: {
                            HStack(spacing: 12) {
                                CardArtThumb(artURL: card.card.artCropURL, fallbackURL: card.card.imageURL)
                                Text(card.card.name)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button("View Card", systemImage: "eye") { onView(card.card) }
                            Divider()
                            Button("To Hand", systemImage: "hand.raised") { onMove(card.id, .hand) }
                            Button("To Battlefield", systemImage: "arrow.up.right") { onMove(card.id, .battlefield) }
                            if title != PlaytestZone.graveyard.label {
                                Button("To Graveyard", systemImage: "archivebox") { onMove(card.id, .graveyard) }
                            }
                            if title != PlaytestZone.exile.label {
                                Button("Exile", systemImage: "xmark.bin") { onMove(card.id, .exile) }
                            }
                            Button("Top of Library", systemImage: "arrow.up.to.line") { onMove(card.id, .library) }
                            if card.isCommander { Button("To Command Zone", systemImage: "crown") { onMove(card.id, .command) } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Move \(card.card.name)")
                    }
                }
            }
            .navigationTitle("\(title) · \(cards.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
