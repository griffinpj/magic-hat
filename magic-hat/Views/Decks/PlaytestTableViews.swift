//
//  PlaytestTableViews.swift
//  magic-hat
//
//  The pieces of the playtest table (see DeckPlaytestView): a card as it
//  sits on the table — turned sideways when tapped, with its power and
//  toughness, loyalty, counters and summoning sickness over it — a pile
//  of identical cards, and the toast that says where a spell went.
//

import SwiftUI

/// One card at the table, tapped or not, with what the table knows about
/// it drawn over its foot.
struct PlaytestCardView: View {
    let card: PlaytestCard
    let width: CGFloat
    /// The game's turn, for summoning sickness.
    var turn = 0
    /// On the battlefield: tapped turns it, badges show.
    var onTable = false
    /// More copies under it, as a pile.
    var pileCount = 1

    private var aspect: Double { card.card.aspectRatio }

    /// The decode size (`CardImageView.targetWidth`: the longest edge, in
    /// points — it multiplies by the screen's scale itself) for a card
    /// drawn `width` wide, rounded up to a few shared sizes so a card is
    /// decoded once for the table, the hand and the zone lists and once
    /// more for the preview and the sheet. It was `width * 2` per size:
    /// three decodes a card, each twice the pixels needed.
    nonisolated static func decodeEdge(for width: CGFloat, aspect: Double) -> CGFloat {
        let edge = width / CGFloat(aspect > 0 ? aspect : 488.0 / 680.0)
        return [160, 224, 352, 512].first { $0 >= edge } ?? (edge / 16).rounded(.up) * 16
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if pileCount > 1 {
                // The cards under it, peeking out to the lower right.
                ForEach(1..<min(pileCount, 3), id: \.self) { depth in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
                        .frame(width: width, height: width / aspect)
                        .offset(x: CGFloat(depth) * 3, y: CGFloat(depth) * 3)
                }
            }
            face
        }
        .frame(width: width + (pileCount > 1 ? 6 : 0), height: width / aspect + (pileCount > 1 ? 6 : 0), alignment: .topLeading)
        .rotationEffect(.degrees(onTable && card.isTapped ? 90 : 0))
        .scaleEffect(onTable && card.isTapped ? aspect : 1)
        .opacity(onTable && card.isTapped ? 0.8 : 1)
        .contentShape(Rectangle())
    }

    private var face: some View {
        Group {
            if let url = card.imageURL {
                CardImageView(urlString: url, aspectRatio: aspect, cornerRadius: 5,
                              targetWidth: Self.decodeEdge(for: width, aspect: aspect),
                              fallbackTargetWidth: width > 120 ? Self.decodeEdge(for: 100, aspect: aspect) : nil)
            } else {
                // No image (an unhydrated card, a token the catalog lacks):
                // a plain card, never a spinner waiting on nothing.
                RoundedRectangle(cornerRadius: 5).fill(Color(.tertiarySystemFill))
            }
        }
            // Opaque, so a card fanned over another hides it as a real one does.
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .topLeading) {
                if card.imageURL == nil {
                    // Name and type where a printed card has them, top left,
                    // so the strip of a card in a fanned hand still reads.
                    VStack(alignment: .leading, spacing: 2) {
                        if width >= 180 {
                            // Large (the inspector, a held card): the card's
                            // words, as its frame would carry them.
                            HStack(alignment: .firstTextBaseline) {
                                Text(card.name).font(.headline)
                                Spacer(minLength: 4)
                                if let cost = card.face.cost, !cost.isEmpty { ManaCostView(cost: cost, size: 14) }
                            }
                            Text(card.face.typeLine).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            if let text = card.card.oracleText, !text.isEmpty {
                                Divider().padding(.vertical, 4)
                                Text(text).font(.caption).lineLimit(10)
                            }
                        } else {
                            Text(card.name)
                                .font(.system(size: width > 80 ? 11 : 9, weight: .semibold))
                                .lineLimit(2)
                            Text(card.face.kind)
                                .font(.system(size: width > 80 ? 9 : 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(width >= 180 ? 12 : 5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) { if onTable { statBadge } }
            .overlay(alignment: .topTrailing) { if onTable { stateBadges } }
            .overlay(alignment: .topLeading) {
                if pileCount > 1 {
                    Text("×\(pileCount)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(3)
                }
            }
            .frame(width: width, height: width / aspect)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
    }

    /// Power/toughness (green when boosted, red when shrunk) or loyalty.
    @ViewBuilder private var statBadge: some View {
        if card.face.isPlaneswalker, let loyalty = card.counters[.loyalty] {
            badge("\(loyalty)", tint: .purple)
        } else if card.face.isCreature, let power = card.power, let toughness = card.toughness {
            badge("\(power)/\(toughness)", tint: card.isBoosted ? .green : card.isShrunk ? .red : .black)
        }
    }

    /// Summoning sickness, and any counters that aren't P/T or loyalty.
    private var stateBadges: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if card.isSummoningSick(on: turn) {
                Image(systemName: "zzz")
                    .font(.system(size: 9, weight: .bold))
                    .padding(3)
                    .background(.black.opacity(0.7), in: Circle())
                    .foregroundStyle(.white)
            }
            if let charge = card.counters[.charge], charge > 0 {
                badge("◆\(charge)", tint: .orange)
            }
            if card.face.isCreature, card.power == nil, let plus = card.counters[.plusOne] {
                badge("+\(plus)", tint: .green)
            }
        }
        .padding(3)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: width > 80 ? 12 : 10, weight: .bold))
            .monospacedDigit()
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
            .padding(3)
    }
}

/// What VoiceOver says for a card at the table.
nonisolated enum PlaytestSpeech {
    static func label(_ card: PlaytestCard, turn: Int, count: Int = 1) -> String {
        var parts = [card.name, card.face.kind]
        if count > 1 { parts.append("\(count) cards") }
        if card.isTapped { parts.append("tapped") }
        if card.isSummoningSick(on: turn) { parts.append("summoning sick") }
        if card.face.isCreature, let p = card.power, let t = card.toughness { parts.append("\(p)/\(t)") }
        if let loyalty = card.counters[.loyalty], card.face.isPlaneswalker { parts.append("loyalty \(loyalty)") }
        if card.isToken { parts.append("token") }
        return parts.joined(separator: ", ")
    }
}

/// The zone strip's buttons: a small tinted capsule, as a small
/// bordered button draws, inside a 44pt target — the bordered style's
/// own hit area is the 28pt capsule, on the table's most-tapped controls.
struct PlaytestChipStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, tint: tint)
    }

    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let color = isEnabled ? tint : Color.secondary
            configuration.label
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(color.opacity(isEnabled ? 0.15 : 0.1), in: Capsule())
                .opacity(configuration.isPressed ? 0.5 : 1)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }
}

/// The banner at the foot of the battlefield while the hand is being
/// chosen from: bottoming after a mulligan, discarding at cleanup.
struct PlaytestBanner: View {
    let text: String
    let systemImage: String
    var tint: Color = .orange

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(tint.opacity(0.35)), in: Capsule())
    }
}

struct PlaytestToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: PlaytestEvent.Kind
}

/// What just happened that the tap didn't show — a spell resolving into
/// the graveyard, a token gone — with Undo beside it.
struct PlaytestToastView: View {
    let toast: PlaytestToast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: PlaytestEventIcon.name(toast.kind))
                .foregroundStyle(.secondary)
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("playtest-toast-undo")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playtest-toast")
    }
}

/// One symbol per kind of event, for the toast and the log.
nonisolated enum PlaytestEventIcon {
    static func name(_ kind: PlaytestEvent.Kind) -> String {
        switch kind {
        case .game: return "flag"
        case .draw: return "rectangle.stack"
        case .land: return "mountain.2"
        case .cast: return "wand.and.stars"
        case .resolve: return "archivebox"
        case .move: return "arrow.right"
        case .token: return "circle.hexagongrid"
        case .combat: return "bolt"
        case .life: return "heart"
        case .library: return "magnifyingglass"
        case .counter: return "plusminus"
        }
    }
}
