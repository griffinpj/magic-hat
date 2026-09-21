import Testing
import Foundation
import UIKit
@testable import magic_hat

/// Runs inside the app host, so Bundle.main is the app and CoreText is live.
/// This is the check that the symbol pipeline actually produces something —
/// the WebKit path could only be verified by eye, and kept failing that.
@Suite("Keyrune set symbols")
struct KeyruneFontTests {
    @Test func fontRegistersAndIsUsable() {
        #expect(KeyruneFont.register())
        let name = KeyruneFont.fontName
        #expect(name != nil)
        #expect(UIFont(name: name ?? "", size: 12) != nil)
    }

    @Test func glyphMapCoversTheCollectionsSets() throws {
        let rows = try CSVParser.parseManaBox(try TestSupport.manaBoxFixture())
        let sets = Set(rows.map { $0.setCode.lowercased() })
        let covered = sets.filter { KeyruneFont.glyph(for: $0) != nil }
        #expect(sets.count > 100)
        #expect(Double(covered.count) / Double(sets.count) > 0.9,
                "Keyrune covers \(covered.count) of \(sets.count) sets")
        #expect(KeyruneFont.glyph(for: "ONE") != nil, "lookup is case-insensitive")
        #expect(KeyruneFont.glyph(for: "pltr") == KeyruneFont.glyph(for: "ltr"), "promos use the parent symbol")
    }

    /// Draws a glyph and checks ink landed: proves font + map + rendering end to end.
    @Test @MainActor func renderedGlyphHasInk() throws {
        let glyph = try #require(KeyruneFont.glyph(for: "one"))
        let fontName = try #require(KeyruneFont.fontName)
        let font = try #require(UIFont(name: fontName, size: 40))
        let size = CGSize(width: 48, height: 48)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            (glyph as NSString).draw(at: .zero, withAttributes: [.font: font, .foregroundColor: UIColor.black])
        }
        let cg = try #require(image.cgImage)
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        let inked = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 40 }.count
        #expect(inked > 50, "glyph drew \(inked) opaque pixels")
    }
}
