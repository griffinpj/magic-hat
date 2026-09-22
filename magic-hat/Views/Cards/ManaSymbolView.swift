//
//  ManaSymbolView.swift
//  magic-hat
//
//  Draws mana symbols the way cards print them: a coloured pip with the
//  Mana-font glyph on it. Hybrids are a diagonally split pip with two
//  half-size glyphs (top-left, bottom-right), Phyrexian a coloured pip with
//  the Φ glyph — the same composition Mana's CSS uses, since the font has
//  no single glyph for those. Pip colours are Mana's cost palette.
//
//  `ManaCostView` lays out a cost string; `OracleTextView` renders rules
//  text with the symbols inline. Inline symbols are rendered once per
//  (symbol, size, scale) into a UIImage and interpolated into Text, which is
//  the only way to get a coloured pip inside a text run.
//

import SwiftUI

// MARK: - One symbol

struct ManaSymbolView: View {
    let symbol: ManaSymbol
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            if !symbol.drawsBare { pip }
            glyphs
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityText)
    }

    /// Mana's composition: {W/U}, {2/W}, {C/W} are two half-size glyphs on a
    /// split pip; {W/U/P} is Φ on both halves; {W/P} and {P} one Φ.
    @ViewBuilder private var glyphs: some View {
        let tl = CGSize(width: -size * 0.19, height: -size * 0.19)
        let br = CGSize(width: size * 0.19, height: size * 0.19)
        if symbol.parts.count == 3 {
            glyph("P", scale: 0.5).offset(tl)
            glyph("P", scale: 0.5).offset(br)
        } else if symbol.isHybrid, !symbol.isPhyrexian {
            glyph(symbol.parts[0], scale: 0.5).offset(tl)
            glyph(symbol.parts[1], scale: 0.5).offset(br)
        } else if symbol.isPhyrexian {
            glyph("P", scale: 0.68)
        } else if let part = symbol.parts.first {
            glyph(part, scale: symbol.drawsBare ? 0.95 : 0.68)
        }
    }

    private func glyph(_ part: String, scale: CGFloat) -> some View {
        Group {
            if let g = ManaFont.glyph(forPart: part), let font = ManaFont.fontName {
                Text(g)
                    .font(.custom(font, size: size * scale))
                    .foregroundStyle(symbol.drawsBare ? Color.primary : ManaPalette.ink)
            } else {
                // Unknown symbol (newer than the font): show the text.
                Text(part)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(ManaPalette.ink)
                    .minimumScaleFactor(0.5)
            }
        }
    }

    @ViewBuilder private var pip: some View {
        if symbol.parts.count == 3 || (symbol.isHybrid && !symbol.isPhyrexian) {
            // Split diagonally, first colour top-left.
            let top = ManaPalette.pip(for: symbol.parts[0])
            let bottom = ManaPalette.pip(for: symbol.parts[1])
            Circle().fill(LinearGradient(stops: [
                .init(color: top, location: 0.5), .init(color: bottom, location: 0.5)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            Circle().fill(symbol.colors.first.map { ManaPalette.color($0) } ?? ManaPalette.generic)
        }
    }

    private var accessibilityText: String {
        symbol.parts.map { part in
            switch part {
            case "T": return "tap"
            case "Q": return "untap"
            case "P": return "Phyrexian"
            case "C": return "colorless"
            case "E": return "energy"
            case "S": return "snow"
            default: return ManaColor(rawValue: part)?.name ?? part
            }
        }.joined(separator: " or ")
    }
}

/// Mana's cost palette (css/mana.css `.ms-cost`).
enum ManaPalette {
    static let generic = Color(red: 0xbe / 255, green: 0xb9 / 255, blue: 0xb2 / 255)
    static let ink = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)

    static func pip(for part: String) -> Color {
        switch part.uppercased() {
        case "W": return Color(red: 0xf0 / 255, green: 0xf2 / 255, blue: 0xc0 / 255)
        case "U": return Color(red: 0xb5 / 255, green: 0xcd / 255, blue: 0xe3 / 255)
        case "B": return Color(red: 0xac / 255, green: 0xa2 / 255, blue: 0x9a / 255)
        case "R": return Color(red: 0xdb / 255, green: 0x86 / 255, blue: 0x64 / 255)
        case "G": return Color(red: 0x93 / 255, green: 0xb4 / 255, blue: 0x83 / 255)
        default: return generic
        }
    }

    static func color(_ c: ManaColor) -> Color { pip(for: c.rawValue) }
}

// MARK: - A named glyph

/// Any single Mana glyph by name — card types ("creature", "instant"),
/// keyword abilities ("ability-flying"), counters — tinted like text.
struct ManaGlyphView: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        if let g = ManaFont.glyph(named: name), let font = ManaFont.fontName {
            Text(g)
                .font(.custom(font, size: size))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - A cost

struct ManaCostView: View {
    let cost: String
    var size: CGFloat = 18

    var body: some View {
        let symbols = ManaSymbol.parse(cost)
        HStack(spacing: size * 0.12) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                ManaSymbolView(symbol: symbol, size: size)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rules text with inline symbols

struct OracleTextView: View {
    let text: String
    var font: Font = .callout
    /// Point size of inline pips; matches the font's cap height roughly.
    var symbolSize: CGFloat = 15

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    Text(" ").font(font)
                } else {
                    lineText(line).font(font)
                }
            }
        }
    }

    private func lineText(_ line: String) -> Text {
        ManaSymbol.segments(in: line).reduce(Text("")) { acc, segment in
            switch segment {
            case .text(let s):
                return acc + Text(s)
            case .symbol(let symbol):
                if let image = ManaSymbolRenderer.image(for: symbol, size: symbolSize, scale: displayScale) {
                    return acc + Text(" ") + Text(Image(uiImage: image)) + Text(" ")
                }
                return acc + Text("{\(symbol.raw)}")
            }
        }
    }
}

/// Renders symbols to bitmaps for inline use, cached per symbol/size/scale.
/// A card mentions a handful of distinct symbols, so this is a few renders
/// per screen, once.
@MainActor
enum ManaSymbolRenderer {
    private static var cache: [String: UIImage] = [:]

    static func image(for symbol: ManaSymbol, size: CGFloat, scale: CGFloat) -> UIImage? {
        let key = "\(symbol.raw)|\(size)|\(scale)"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: ManaSymbolView(symbol: symbol, size: size))
        renderer.scale = scale
        guard let image = renderer.uiImage else { return nil }
        cache[key] = image
        return image
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ManaCostView(cost: "{2}{G}{W}", size: 22)
        ManaCostView(cost: "{W/U}{2/B}{R/P}{G/U/P}{C}{X}{T}{Q}{S}{E}{∞}{½}", size: 22)
        OracleTextView(text: "{T}: Add {G}.\n{2}{W}, {T}: Draw a card.\nFlying, vigilance")
    }
    .padding()
}
