import Testing
import Foundation
import UIKit
@testable import magic_hat

@Suite("Mana symbols")
struct ManaSymbolTests {
    @Test func parsesCostTokens() {
        let symbols = ManaSymbol.parse("{2}{G}{W/U}{R/P}{T}")
        #expect(symbols.map(\.raw) == ["2", "G", "W/U", "R/P", "T"])
        #expect(symbols[0].isGeneric)
        #expect(symbols[1].colors == [.green])
        #expect(symbols[2].isHybrid && !symbols[2].isPhyrexian)
        #expect(symbols[3].isPhyrexian && symbols[3].colors == [.red])
        #expect(symbols[4].colors.isEmpty)
    }

    @Test func manaValueFollowsScryfall() {
        #expect(ManaSymbol.manaValue(of: "{2}{G}{W}") == 4)
        #expect(ManaSymbol.manaValue(of: "{X}{R}{R}") == 2)
        #expect(ManaSymbol.manaValue(of: "{2/W}{2/W}") == 4)
        #expect(ManaSymbol.manaValue(of: "") == 0)
    }

    @Test func segmentsKeepTextAroundSymbols() {
        let segs = ManaSymbol.segments(in: "{T}: Add {G}. Draw a card.")
        #expect(segs == [.symbol(ManaSymbol("T")), .text(": Add "), .symbol(ManaSymbol("G")), .text(". Draw a card.")])
        // Braces with spaces inside aren't symbols.
        #expect(ManaSymbol.segments(in: "a {not a symbol} b") == [.text("a {not a symbol} b")])
    }

    @Test func fontRegistersAndCoversTheCommonSymbols() {
        #expect(ManaFont.register())
        #expect(UIFont(name: ManaFont.fontName ?? "", size: 12) != nil)
        for part in ["W", "U", "B", "R", "G", "C", "0", "1", "10", "20", "X", "T", "Q", "E", "S", "P", "∞", "½", "CHAOS"] {
            #expect(ManaFont.glyph(forPart: part) != nil, "missing glyph for \(part)")
        }
        for type in ["creature", "instant", "sorcery", "artifact", "enchantment", "land", "planeswalker", "battle"] {
            #expect(ManaFont.glyph(named: type) != nil, "missing card-type glyph \(type)")
        }
        #expect(ManaFont.glyph(named: "ability-flying") != nil)
    }

    /// Draws the green pip glyph and checks ink landed — the same end-to-end
    /// proof the Keyrune test does.
    @Test @MainActor func renderedGlyphHasInk() throws {
        let glyph = try #require(ManaFont.glyph(forPart: "G"))
        let fontName = try #require(ManaFont.fontName)
        let font = try #require(UIFont(name: fontName, size: 40))
        let size = CGSize(width: 48, height: 48)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            (glyph as NSString).draw(at: .zero, withAttributes: [.font: font, .foregroundColor: UIColor.black])
        }
        let cg = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8,
                            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(origin: .zero, size: CGSize(width: cg.width, height: cg.height)))
        let inked = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 40 }.count
        #expect(inked > 50, "glyph drew \(inked) opaque pixels")
    }

    /// The inline renderer must produce a bitmap for a hybrid, which has no
    /// single glyph and is composed from two.
    @Test @MainActor func inlineRendererComposesHybrids() {
        let image = ManaSymbolRenderer.image(for: ManaSymbol("W/U"), size: 16, scale: 2)
        #expect(image != nil)
        #expect((image?.size.width ?? 0) >= 16)
    }
}
