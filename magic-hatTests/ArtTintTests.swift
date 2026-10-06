//
//  ArtTintTests.swift
//  magic-hatTests
//
//  The glow behind a tile is sampled from the card's edge: a drawn card
//  with a known frame proves the samples land where they should — top is
//  the top (Core Graphics' bitmap rows run top-down), left is left — and
//  that a split frame yields two colours.
//

import Testing
import UIKit
@testable import magic_hat

@Suite("ArtTint")
struct ArtTintTests {
    /// A 488×680 "card": a black border, then a frame whose left half is
    /// red and right half white, art (green) in the middle.
    private func card(top: UIColor = .red, bottom: UIColor = .red, left: UIColor? = nil, right: UIColor? = nil) -> CGImage {
        let size = CGSize(width: 488, height: 680)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let image = renderer.image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let frame = CGRect(x: 22, y: 22, width: size.width - 44, height: size.height - 44)
            if let left, let right {
                left.setFill(); ctx.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height))
                right.setFill(); ctx.fill(CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height))
            } else {
                top.setFill(); ctx.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2))
                bottom.setFill(); ctx.fill(CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2))
            }
            UIColor.green.setFill(); ctx.fill(frame.insetBy(dx: 90, dy: 120))
        }
        return image.cgImage!
    }

    private func isRed(_ c: SIMD3<Float>) -> Bool { c.x > 0.6 && c.y < 0.35 && c.z < 0.35 }
    private func isBlue(_ c: SIMD3<Float>) -> Bool { c.z > 0.6 && c.x < 0.35 && c.y < 0.35 }
    private func isLight(_ c: SIMD3<Float>) -> Bool { c.x > 0.6 && c.y > 0.6 && c.z > 0.6 }

    @Test func topIsTopAndBottomIsBottom() throws {
        let tint = try #require(ArtTint.extract(card(top: .red, bottom: .blue)))
        #expect(isRed(tint.samples[0]) && isRed(tint.samples[1]) && isRed(tint.samples[2]), "top row red: \(tint.samples)")
        #expect(isBlue(tint.samples[6]) && isBlue(tint.samples[7]) && isBlue(tint.samples[8]), "bottom row blue")
        #expect(tint.samples.count == 9)
    }

    @Test func aSplitFrameBleedsTwoColours() throws {
        let tint = try #require(ArtTint.extract(card(left: .red, right: .white)))
        #expect(isRed(tint.samples[0]) && isRed(tint.samples[3]) && isRed(tint.samples[6]), "left column red")
        #expect(isLight(tint.samples[2]) && isLight(tint.samples[5]) && isLight(tint.samples[8]), "right column white (kept off pure white)")
    }

    /// The frame, not the border: a black border around a red frame reads red.
    @Test func theBorderIsSkipped() throws {
        let tint = try #require(ArtTint.extract(card()))
        #expect(tint.samples.allSatisfy(isRed), "\(tint.samples)")
    }
}
