//
//  ArtTintTests.swift
//  magic-hatTests
//
//  The glow behind a tile is sampled from the card's picture: a drawn
//  card with a known frame and a known art box proves the samples land
//  inside the art — top is the picture's top (Core Graphics' bitmap rows
//  run top-down), left is left — and that a white frame with its title
//  bar and text box never reaches the glow.
//

import Testing
import UIKit
@testable import magic_hat

@Suite("ArtTint")
struct ArtTintTests {
    private let size = CGSize(width: 488, height: 680)

    /// A 488×680 "card": a black border, a frame in `frame` (a white
    /// card's title bar, type line and text box included), and a picture
    /// in the standard art box painted in halves — top/bottom, or
    /// left/right.
    private func card(frame: UIColor = .white, top: UIColor = .orange, bottom: UIColor = .blue,
                      left: UIColor? = nil, right: UIColor? = nil) -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            frame.setFill(); ctx.fill(CGRect(x: 22, y: 22, width: size.width - 44, height: size.height - 44))
            let box = ArtTint.artBox
            let art = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
            if let left, let right {
                left.setFill(); ctx.fill(CGRect(x: art.minX, y: art.minY, width: art.width / 2, height: art.height))
                right.setFill(); ctx.fill(CGRect(x: art.midX, y: art.minY, width: art.width / 2, height: art.height))
            } else {
                top.setFill(); ctx.fill(CGRect(x: art.minX, y: art.minY, width: art.width, height: art.height / 2))
                bottom.setFill(); ctx.fill(CGRect(x: art.minX, y: art.midY, width: art.width, height: art.height / 2))
            }
            // A text box below the art, as on every card: white, with
            // grey lines of "text".
            UIColor(white: 0.97, alpha: 1).setFill()
            ctx.fill(CGRect(x: art.minX, y: art.maxY + 40, width: art.width, height: 180))
            UIColor.darkGray.setFill()
            for i in 0..<5 { ctx.fill(CGRect(x: art.minX + 12, y: art.maxY + 60 + CGFloat(i) * 30, width: art.width - 24, height: 6)) }
        }
        return image.cgImage!
    }

    private func isOrange(_ c: SIMD3<Float>) -> Bool { c.x > 0.7 && c.y > 0.25 && c.y < 0.75 && c.z < 0.3 }
    private func isBlue(_ c: SIMD3<Float>) -> Bool { c.z > 0.6 && c.x < 0.35 && c.y < 0.35 }
    private func isRed(_ c: SIMD3<Float>) -> Bool { c.x > 0.6 && c.y < 0.35 && c.z < 0.35 }
    private func isGreen(_ c: SIMD3<Float>) -> Bool { c.y > 0.6 && c.x < 0.35 && c.z < 0.35 }
    private func isLight(_ c: SIMD3<Float>) -> Bool { c.x > 0.75 && c.y > 0.75 && c.z > 0.75 }

    @Test func topOfTheArtIsTopAndBottomIsBottom() throws {
        let tint = try #require(ArtTint.extract(card(top: .orange, bottom: .blue)))
        #expect(isOrange(tint.samples[0]) && isOrange(tint.samples[1]) && isOrange(tint.samples[2]), "top row orange: \(tint.samples)")
        #expect(isBlue(tint.samples[6]) && isBlue(tint.samples[7]) && isBlue(tint.samples[8]), "bottom row blue")
        #expect(tint.samples.count == 9)
    }

    @Test func leftAndRightOfTheArtBleedSeparately() throws {
        let tint = try #require(ArtTint.extract(card(left: .red, right: .green)))
        #expect(isRed(tint.samples[0]) && isRed(tint.samples[3]) && isRed(tint.samples[6]), "left column red")
        #expect(isGreen(tint.samples[2]) && isGreen(tint.samples[5]) && isGreen(tint.samples[8]), "right column green")
    }

    /// A white card's frame, title bar and text box never reach the glow:
    /// with a blue picture every sample is blue, none light.
    @Test func theWhiteFrameAndTextBoxAreNeverSampled() throws {
        let tint = try #require(ArtTint.extract(card(frame: .white, top: .blue, bottom: .blue)))
        #expect(tint.samples.allSatisfy(isBlue), "\(tint.samples)")
        #expect(!tint.samples.contains(where: isLight))
    }
}
