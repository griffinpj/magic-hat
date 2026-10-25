//
//  PlaytestInspector.swift
//  magic-hat
//
//  The table's own sheet for one card: it slides up from the hand (or the
//  battlefield, the command zone, a zone's list) and a swipe down puts it
//  away. The card large, where it is (in hand, tapped on the battlefield,
//  in the command zone with its tax), and what it can do from there
//  (`PlaytestState.options`) — the way it is played first, with where it
//  will go and what it will tap, then counters for a permanent, then
//  everywhere else it can be put. Nothing from the collection: no prices,
//  printings, or adding to decks. A double-faced card turns over to read
//  its back.
//
//  The sheet is as tall as what it holds (the table sets the detent from
//  `onHeight`, short of the top so the table stays in view) and scrolls
//  past that; the card's size comes from the table's, not the sheet's,
//  so the height doesn't chase itself.
//

import SwiftUI

struct PlaytestInspector: View {
    let card: PlaytestCard
    let whereabouts: String
    let options: [PlaytestOption]
    let counters: [(kind: PlaytestCounter, value: Int)]
    let cardWidth: CGFloat
    let onOption: (PlaytestOption) -> Void
    let onCounter: (PlaytestCounter, Int) -> Void
    let onHeight: (CGFloat) -> Void
    let onClose: () -> Void

    @State private var showsOtherFace = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasOtherFace: Bool { card.card.backImageURL != nil }
    private var shown: PlaytestCard {
        var shown = card
        if showsOtherFace { shown.showsBack.toggle() }
        return shown
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                face(width: cardWidth)
                header
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 16)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(16)
                .accessibilityIdentifier("playtest-inspector-close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("playtest-inspector")
    }

    // MARK: The card

    private func face(width: CGFloat) -> some View {
        PlaytestCardView(card: shown, width: width)
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            // Turned over in 3D; with Reduce Motion the other face just
            // fades in.
            .rotation3DEffect(.degrees(showsOtherFace && !reduceMotion ? 180 : 0), axis: (x: 0, y: 1, z: 0))
            .scaleEffect(x: showsOtherFace && !reduceMotion ? -1 : 1)
            .id(reduceMotion ? showsOtherFace : false)
            .transition(.opacity)
            .onTapGesture { if hasOtherFace { flip() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(shown.name)
            .accessibilityValue(card.card.oracleText ?? "")
            // After the card's own element, so VoiceOver reaches it.
            .overlay(alignment: .bottomTrailing) {
                if hasOtherFace {
                    Button("Turn Over", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", action: flip)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .offset(x: 14, y: 14)
                        .accessibilityIdentifier("playtest-inspector-flip")
                }
            }
    }

    private func flip() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45)) { showsOtherFace.toggle() }
    }

    private var header: some View {
        // The card itself carries its name and cost; under it, what the
        // table knows that the printed card doesn't.
        VStack(spacing: 4) {
            Text(statLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(whereabouts)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityIdentifier("playtest-inspector-where")
        }
        .frame(maxWidth: .infinity)
    }

    /// "Creature — Elf Druid · 2/2" — with counters, the numbers as they are.
    private var statLine: String {
        var parts = [shown.face.typeLine]
        if shown.face.isCreature, let p = shown.power, let t = shown.toughness { parts.append("\(p)/\(t)") }
        if shown.face.isPlaneswalker, let loyalty = card.counters[.loyalty] ?? card.info.loyalty { parts.append("Loyalty \(loyalty)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Actions

    /// The ways to play it (and the primary action), drawn as wide
    /// buttons with captions; the rest go in a two-column grid.
    private static func partition(_ options: [PlaytestOption]) -> (plays: [PlaytestOption], rest: [PlaytestOption]) {
        let plays = options.filter { if case .play = $0.command { return true } else { return $0.isPrimary } }
        return (plays, options.filter { !plays.contains($0) })
    }

    /// The sheet's height before it has measured itself: the table sets
    /// the detent from this as it presents the sheet, so a card doesn't
    /// open at the last card's height and then animate to its own. The
    /// measured height (`onHeight`) replaces it a frame later.
    static func estimatedHeight(options: [PlaytestOption], counters: Int, cardWidth: CGFloat) -> CGFloat {
        let (plays, rest) = partition(options)
        var height: CGFloat = 30 + cardWidth / (488.0 / 680.0) + 16 + 44
        if !plays.isEmpty {
            height += 16 + CGFloat(plays.count) * 52 + CGFloat(plays.count - 1) * 10
            height += CGFloat(plays.filter { !($0.caption ?? "").isEmpty }.count) * 40
        }
        if counters > 0 { height += 16 + CGFloat(counters) * 55 }
        if !rest.isEmpty {
            height += 16 + CGFloat((rest.count + 1) / 2) * 48
            if rest.contains(where: { $0.caption != nil }) { height += 26 }
        }
        return height + 16
    }

    @ViewBuilder private var actions: some View {
        let (plays, rest) = Self.partition(options)
        VStack(spacing: 10) {
            ForEach(plays) { option in
                VStack(spacing: 5) {
                    playButton(option)
                        .controlSize(.large)
                        .accessibilityIdentifier(option.isPrimary ? "playtest-inspector-primary" : "playtest-option-\(option.title)")
                    if let caption = option.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        if !counters.isEmpty { counterPanel }
        if !rest.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(rest) { option in
                    Button {
                        choose(option)
                    } label: {
                        Label(option.title, systemImage: option.systemImage)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(option.isDestructive ? .red : nil)
                    .accessibilityIdentifier("playtest-option-\(option.title)")
                }
            }
            if let note = rest.compactMap(\.caption).first {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func playButton(_ option: PlaytestOption) -> some View {
        let button = Button {
            choose(option)
        } label: {
            Label(option.title, systemImage: option.systemImage)
                .frame(maxWidth: .infinity)
        }
        if option.isPrimary {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var counterPanel: some View {
        VStack(spacing: 0) {
            ForEach(Array(counters.enumerated()), id: \.element.kind) { index, counter in
                if index > 0 { Divider() }
                HStack {
                    Text(counter.kind.label).font(.body.weight(.medium))
                    Spacer()
                    Button("Remove", systemImage: "minus") { onCounter(counter.kind, -1) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .disabled(counter.value == 0)
                        .accessibilityLabel("Remove \(counter.kind.label)")
                    Text("\(counter.value)")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(counter.value)))
                        .frame(minWidth: 36)
                        .accessibilityIdentifier("playtest-counter-\(counter.kind.rawValue)")
                    Button("Add", systemImage: "plus") { onCounter(counter.kind, 1) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Add \(counter.kind.label)")
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 14)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }

    private func choose(_ option: PlaytestOption) {
        onOption(option)
        if !option.keepsOpen { onClose() }
    }
}

