//
//  PlaytestHand.swift
//  magic-hat
//
//  The hand as it is held: fanned along the foot of the screen, each card
//  turned a few degrees from the middle and dipping toward the edges, the
//  bottoms tucked off the screen the way the bottom of a held hand is
//  hidden by the fingers. A card shows its top — name, cost and art.
//
//  One touch does three things, decided by how the finger moves:
//  - a tap opens the card's sheet (PlaytestInspector: its actions);
//  - holding still — barely more than a tap (PlaytestTouchTiming) — lifts
//    it into a large preview above the hand, and sliding sideways while
//    holding moves the preview along the hand;
//  - dragging up carries it to the battlefield. Past the line above the
//    hand the table lights up ("Release to cast…") and letting go plays
//    it; let go short of the line and it goes back into the hand.
//
//  The whole fan is one gesture (cards overlap and turn, so which card a
//  finger is on is worked out from the layout, not from hit-testing the
//  rotated views). For VoiceOver and UI tests each card is also an
//  invisible element over the strip of it that shows, with Play as an
//  action.
//

import SwiftUI

/// Where each card of a fanned hand sits.
nonisolated struct PlaytestFanLayout: Hashable, Sendable {
    struct Slot: Hashable, Sendable {
        /// Centre of the card, horizontally.
        let x: CGFloat
        /// Top of the card.
        let top: CGFloat
        /// Degrees, clockwise; turned about the card's foot.
        let angle: Double
    }

    let count: Int
    let width: CGFloat
    let cardWidth: CGFloat
    /// Space above the cards, for a lifted one.
    static let headroom: CGFloat = 14

    /// The outermost cards' turn, in degrees: a few per card, at most ten.
    private var maxAngle: Double { min(10, 2.6 * Double(middle)) }

    /// The distance between neighbours: most of a card when few, closing
    /// up so the fan — turned, its outer corners swinging out — never runs
    /// off the screen.
    var step: CGFloat {
        guard count > 1 else { return 0 }
        let swing = cardWidth / (488.0 / 680.0) * CGFloat(sin(maxAngle * .pi / 180))
        let spread = max(0, width - cardWidth - 2 * swing - 12)
        return min(cardWidth * 0.78, spread / CGFloat(count - 1))
    }

    private var middle: CGFloat { CGFloat(count - 1) / 2 }

    func slot(_ i: Int) -> Slot {
        let offset = CGFloat(i) - middle
        let angleStep = middle > 0 ? maxAngle / Double(middle) : 0
        let dip = middle > 0 ? min(2.6, 16 / (middle * middle)) : 0
        return Slot(x: width / 2 + offset * step, top: Self.headroom + offset * offset * dip,
                    angle: Double(offset) * angleStep)
    }

    /// The part of card `i` that shows: from its left edge to where the
    /// next card covers it.
    func strip(_ i: Int) -> (minX: CGFloat, maxX: CGFloat) {
        let left = slot(i).x - cardWidth / 2
        let right = i == count - 1 ? slot(i).x + cardWidth / 2 : slot(i + 1).x - cardWidth / 2
        return (left, max(right, left + 1))
    }

    /// The card under `x`: the topmost one reaching it, each card lying
    /// over the one before.
    func index(at x: CGFloat) -> Int? {
        for i in stride(from: count - 1, through: 0, by: -1) {
            let centre = slot(i).x
            if x >= centre - cardWidth / 2, x <= centre + cardWidth / 2 { return i }
        }
        return nil
    }
}

/// A touch on the hand: when it is a tap and when a look. The preview
/// comes up almost at once, as a card game's does; a release that soon
/// that never moved is still a tap — the card's sheet opens, the preview
/// having barely shown — so a quick tap and a deliberate look both read.
nonisolated enum PlaytestTouchTiming {
    /// A finger held this long lifts the card into the large preview.
    static let previewDelay: Duration = .milliseconds(120)
    /// A release within this, without wandering, is a tap.
    static let tapLimit: TimeInterval = 0.22
    /// Movement past this is a drag or a scrub, never a tap.
    static let slop: CGFloat = 10

    static func isTap(held: TimeInterval, wandered: Bool) -> Bool { !wandered && held < tapLimit }
}

/// What the cards in hand are for at the moment.
enum PlaytestHandMode: Equatable {
    /// Before turn one: look, don't play.
    case looking
    /// The turn: drag to play.
    case playing
    /// Choosing cards to bottom (a mulligan) or discard (cleanup): a tap
    /// takes the card.
    case choosing(systemImage: String, tint: Color)
}

struct PlaytestHand: View {
    let cards: [PlaytestCard]
    let mode: PlaytestHandMode
    let onTap: (PlaytestCard) -> Void
    let onPlay: (PlaytestCard) -> Void
    /// The card being carried over the battlefield, past the line: the
    /// table lights up for it.
    @Binding var armed: PlaytestCard?
    /// A card's width in the fan: 100pt on a phone, more on a wide table.
    var cardWidth: CGFloat = Self.defaultCardWidth
    /// The room above the hand for the held card's preview: on a phone on
    /// its side the 250pt card (348pt tall) ran off the top of the screen.
    var previewMaxHeight: CGFloat = .infinity

    static let defaultCardWidth: CGFloat = 100
    static let previewWidth: CGFloat = 250
    /// How much of the fan shows above the screen's edge, per point of
    /// card width (118pt for a 100pt card).
    static let visibleShare: CGFloat = 1.18
    static func visibleHeight(cardWidth: CGFloat) -> CGFloat { (cardWidth * visibleShare).rounded() }
    /// How far above the hand a carried card has to go to be played.
    static let playLine: CGFloat = -70
    private static let aspect: CGFloat = 488.0 / 680.0
    private var cardHeight: CGFloat { cardWidth / Self.aspect }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Touch: Equatable {
        /// Down, not yet a hold or a drag.
        case pressing(Int)
        /// Held: the big preview, which follows the finger along the hand.
        case inspecting(Int)
        /// Carried toward the battlefield.
        case dragging(Int)

        var index: Int {
            switch self {
            case .pressing(let i), .inspecting(let i), .dragging(let i): return i
            }
        }
    }

    @State private var touch: Touch?
    @State private var touchBegan = Date.distantPast
    @State private var wandered = false
    @State private var finger: CGPoint = .zero
    @State private var holdTask: Task<Void, Never>?
    @State private var lifted = 0
    @State private var scrubbed = 0
    @State private var crossed = 0

    var body: some View {
        GeometryReader { geo in
            let layout = PlaytestFanLayout(count: cards.count, width: geo.size.width, cardWidth: cardWidth)
            ZStack(alignment: .topLeading) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                    fanned(card, at: i, layout: layout)
                }
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                    accessibilityStrip(card, at: i, layout: layout, height: geo.size.height)
                }
                if case .inspecting(let i) = touch, cards.indices.contains(i) {
                    preview(cards[i], at: layout.slot(i).x, width: geo.size.width)
                }
                if case .dragging(let i) = touch, cards.indices.contains(i) {
                    carried(cards[i])
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(gesture(layout))
        }
        .frame(height: Self.visibleHeight(cardWidth: cardWidth))
        .sensoryFeedback(.impact(weight: .light), trigger: lifted)
        .sensoryFeedback(.selection, trigger: scrubbed)
        .sensoryFeedback(.impact(weight: .medium), trigger: crossed)
        .onChange(of: cards.map(\.id)) { touch = nil; armed = nil }
    }

    // MARK: Drawing

    private func fanned(_ card: PlaytestCard, at i: Int, layout: PlaytestFanLayout) -> some View {
        let slot = layout.slot(i)
        let isTouched = touch?.index == i
        let lift: CGFloat = isTouched && touch != nil ? 22 : 0
        return PlaytestCardView(card: card, width: cardWidth)
            // In the strip of the card that shows, not under its neighbour.
            .overlay(alignment: .topLeading) {
                if case .choosing(let symbol, let tint) = mode {
                    Image(systemName: symbol)
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, tint)
                        .padding(.leading, 7)
                        .padding(.top, 40)
                }
            }
            .rotationEffect(.degrees(isTouched ? 0 : slot.angle), anchor: .bottom)
            .position(x: slot.x, y: slot.top - lift + cardHeight / 2)
            .opacity(isDragged(i) ? 0.3 : 1)
            .zIndex(Double(i))
            // The lift and straightening jump into place under Reduce Motion.
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: touch)
            .accessibilityHidden(true)
    }

    private func isDragged(_ i: Int) -> Bool {
        if case .dragging(let j) = touch { return i == j }
        return false
    }

    /// The card big, above the hand, while it is held.
    private func preview(_ card: PlaytestCard, at x: CGFloat, width: CGFloat) -> some View {
        let w = Self.previewWidth(cardWidth: cardWidth, maxHeight: previewMaxHeight)
        let h = w / Self.aspect
        return PlaytestCardView(card: card, width: w)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .position(x: min(max(x, w / 2 + 12), width - w / 2 - 12), y: -h / 2 - 10)
            .zIndex(1000)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The preview's width: 250pt scaled with the hand's cards, and no
    /// taller than the room above the hand (10pt clear of it).
    static func previewWidth(cardWidth: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let wanted = previewWidth * cardWidth / defaultCardWidth
        return max(cardWidth, min(wanted, (maxHeight - 20) * aspect))
    }

    /// The card under the finger, a little above it so it isn't covered.
    private func carried(_ card: PlaytestCard) -> some View {
        PlaytestCardView(card: card, width: cardWidth)
            .scaleEffect(reduceMotion ? 1 : armed != nil ? 0.9 : 1.08)
            .shadow(color: .black.opacity(0.4), radius: armed != nil ? 6 : 14, y: 6)
            .position(x: finger.x, y: finger.y - cardHeight / 2 - 10)
            .zIndex(1001)
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: armed != nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// An invisible element over the strip of the card that shows.
    private func accessibilityStrip(_ card: PlaytestCard, at i: Int, layout: PlaytestFanLayout, height: CGFloat) -> some View {
        let strip = layout.strip(i)
        let top = layout.slot(i).top
        return Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: strip.maxX - strip.minX, height: max(1, height - top))
            .position(x: (strip.minX + strip.maxX) / 2, y: top + (height - top) / 2)
            .accessibilityElement()
            .accessibilityLabel(card.name)
            .accessibilityValue(card.info.front.kind)
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap(card) }
            .accessibilityAction(named: "Play") { if mode == .playing { onPlay(card) } }
            .accessibilityIdentifier("playtest-hand-\(card.name)")
    }

    private var hint: String {
        switch mode {
        case .looking: return "Opens the card."
        case .playing: return "Opens the card. Drag up to play it."
        case .choosing: return "Chooses it."
        }
    }

    // MARK: The touch

    private func gesture(_ layout: PlaytestFanLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if touch == nil {
                    guard let i = layout.index(at: value.startLocation.x) else { return }
                    touch = .pressing(i)
                    touchBegan = .now
                    wandered = false
                    holdTask?.cancel()
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: PlaytestTouchTiming.previewDelay)
                        guard !Task.isCancelled, case .pressing(let j) = touch else { return }
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.14)) { touch = .inspecting(j) }
                        lifted += 1
                    }
                }
                let moved = hypot(value.translation.width, value.translation.height)
                if moved > PlaytestTouchTiming.slop, !wandered { wandered = true }
                guard let current = touch else { return }
                switch current {
                case .pressing(let i):
                    guard moved > PlaytestTouchTiming.slop else { return }
                    holdTask?.cancel()
                    if mode == .playing, value.translation.height < 0, abs(value.translation.height) > abs(value.translation.width) {
                        touch = .dragging(i)
                    } else {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.14)) { touch = .inspecting(layout.index(at: value.location.x) ?? i) }
                        lifted += 1
                    }
                case .inspecting(let i):
                    if mode == .playing, value.location.y < -20 {
                        touch = .dragging(i)
                    } else if value.location.y >= -20, let j = layout.index(at: value.location.x), j != i {
                        touch = .inspecting(j)
                        scrubbed += 1
                    }
                case .dragging(let i):
                    let over = mode == .playing && value.location.y < Self.playLine
                    if over != (armed != nil) {
                        // Animated, so the lit battlefield fades in and out.
                        withAnimation(.snappy(duration: 0.15)) { armed = over ? cards[i] : nil }
                        if over { crossed += 1 }
                    }
                }
                // Only a carried card follows the finger: written on every
                // move of a press or a look too, it re-rendered the hand at
                // touch rate for nothing.
                if case .dragging = touch, finger != value.location { finger = value.location }
            }
            .onEnded { _ in
                holdTask?.cancel()
                let ended = touch
                let play = armed
                let tapped = PlaytestTouchTiming.isTap(held: Date.now.timeIntervalSince(touchBegan), wandered: wandered)
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                    touch = nil
                    armed = nil
                }
                switch ended {
                case .pressing(let i), .inspecting(let i):
                    if tapped, cards.indices.contains(i) { onTap(cards[i]) }
                case .dragging:
                    if let play { onPlay(play) }
                case nil:
                    break
                }
            }
    }
}
