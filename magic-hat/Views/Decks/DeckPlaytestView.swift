//
//  DeckPlaytestView.swift
//  magic-hat
//
//  The table (see Playtest): the battlefield across the top, lands on one
//  row and spells on the next, the hand along the bottom, the command
//  zone beside it, and a status line between — turn, library, untapped
//  lands, graveyard and exile (tap either to look through it). One bar of
//  actions: Draw, Mulligan, Next Turn; New Game and Shuffle in the menu.
//
//  Gestures are the ones a hand makes with real cards: tap a card in hand
//  to play it, tap a card on the battlefield to tap or untap it, hold any
//  card for everywhere else it could go (graveyard, exile, hand, the top
//  or bottom of the library, the command zone for a commander) and to
//  look at it. A London mulligan draws seven and then asks for the cards
//  to put on the bottom: tap them in hand, with a banner counting down.
//  Everything is one `PlaytestState` value in `@State`; every move is a
//  mutation of it, so the screen can never disagree with the count.
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
            .fullScreenCover(item: $viewing) { card in
                CardViewerView(items: CardItemList([card]), currentID: .constant(card.id), showsDetail: false)
            }
            .sheet(item: $browsing) { zone in
                ZoneSheet(title: zone.label, cards: cards(in: zone)) { id, to in state.move(id, to: to) }
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

    private var battlefield: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if state.battlefield.isEmpty {
                    Text(state.hand.isEmpty ? "Draw to begin." : "Tap a card in hand to play it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    if !state.landsOnBattlefield.isEmpty {
                        zoneRow("Lands", state.landsOnBattlefield)
                    }
                    if !state.spellsOnBattlefield.isEmpty {
                        zoneRow("Spells", state.spellsOnBattlefield)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func zoneRow(_ title: String, _ cards: [PlaytestCard]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(cards.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(cards) { card in
                    TableCard(card: card, width: 64)
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { state.toggleTap(card.id) } }
                        .contextMenu { cardMenu(card) }
                        .accessibilityLabel("\(card.card.name)\(card.isTapped ? ", tapped" : "")")
                        .accessibilityHint("Tap to \(card.isTapped ? "untap" : "tap")")
                        .accessibilityIdentifier("playtest-battlefield-\(card.card.name)")
                }
            }
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
                Divider().frame(height: 120)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(state.hand) { card in
                        TableCard(card: card, width: 84)
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.25)) {
                                    if state.pendingBottom > 0 { state.bottom(card.id) } else { state.play(card.id) }
                                }
                            }
                            .contextMenu { cardMenu(card) }
                            .accessibilityLabel(card.card.name)
                            .accessibilityHint(state.pendingBottom > 0 ? "Tap to put on the bottom of the library" : "Tap to play")
                            .accessibilityIdentifier("playtest-hand-\(card.card.name)")
                    }
                    if state.hand.isEmpty {
                        Text("No cards in hand")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(height: 120)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 148)
        .accessibilityIdentifier("playtest-hand")
    }

    private var commandZone: some View {
        VStack(spacing: 4) {
            ForEach(state.command) { card in
                TableCard(card: card, width: 56)
                    .onTapGesture { withAnimation(.snappy(duration: 0.25)) { state.play(card.id) } }
                    .contextMenu { cardMenu(card) }
                    .accessibilityLabel("\(card.card.name), command zone")
                    .accessibilityHint("Tap to cast")
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
        if zone != .battlefield { Button("Play", systemImage: "arrow.up.right") { withAnimation { state.play(card.id) } } }
        if zone != .hand { Button("To Hand", systemImage: "hand.raised") { withAnimation { state.move(card.id, to: .hand) } } }
        if zone != .graveyard { Button("To Graveyard", systemImage: "archivebox") { withAnimation { state.move(card.id, to: .graveyard) } } }
        if zone != .exile { Button("Exile", systemImage: "xmark.bin") { withAnimation { state.move(card.id, to: .exile) } } }
        Button("Top of Library", systemImage: "arrow.up.to.line") { withAnimation { state.move(card.id, to: .library, libraryEnd: .top) } }
        Button("Bottom of Library", systemImage: "arrow.down.to.line") { withAnimation { state.move(card.id, to: .library, libraryEnd: .bottom) } }
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
                    .accessibilityIdentifier("playtest-draw")
                Button("Mulligan", systemImage: "arrow.triangle.2.circlepath") { withAnimation { state.mulligan() } }
                    .disabled(state.turn > 1 || state.pendingBottom > 0)
                    .accessibilityIdentifier("playtest-mulligan")
                Spacer()
                Button("Next Turn", systemImage: "arrow.right.circle") { withAnimation { state.nextTurn(); drew += 1 } }
                    .disabled(state.pendingBottom > 0)
                    .fixedSize()
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("playtest-next-turn")
            }
            .buttonStyle(.glass)
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
/// its name as a label when there is no image yet.
private struct TableCard: View {
    let card: PlaytestCard
    let width: CGFloat

    var body: some View {
        CardImageView(urlString: card.card.imageURL, aspectRatio: card.card.aspectRatio, cornerRadius: 4, targetWidth: width * 2)
            .overlay {
                if card.card.imageURL == nil {
                    Text(card.card.name)
                        .font(.system(size: 9, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(4)
                }
            }
            .frame(width: width)
            .rotationEffect(.degrees(card.isTapped ? 90 : 0))
            .scaleEffect(card.isTapped ? card.card.aspectRatio : 1)
            .frame(width: width, height: width / card.card.aspectRatio)
            .opacity(card.isTapped ? 0.75 : 1)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .contentShape(Rectangle())
    }
}

/// A zone's cards as a list — graveyard or exile — each with the moves
/// back out of it.
private struct ZoneSheet: View {
    let title: String
    let cards: [PlaytestCard]
    let onMove: (UUID, PlaytestZone) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if cards.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                }
                ForEach(cards.reversed()) { card in
                    HStack(spacing: 12) {
                        CardArtThumb(artURL: card.card.artCropURL, fallbackURL: card.card.imageURL)
                        Text(card.card.name)
                        Spacer()
                        Menu {
                            Button("To Hand", systemImage: "hand.raised") { onMove(card.id, .hand) }
                            Button("To Battlefield", systemImage: "arrow.up.right") { onMove(card.id, .battlefield) }
                            Button("To Graveyard", systemImage: "archivebox") { onMove(card.id, .graveyard) }
                            Button("Exile", systemImage: "xmark.bin") { onMove(card.id, .exile) }
                            Button("Top of Library", systemImage: "arrow.up.to.line") { onMove(card.id, .library) }
                            if card.isCommander { Button("To Command Zone", systemImage: "crown") { onMove(card.id, .command) } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
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
