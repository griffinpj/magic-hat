import Testing
import Foundation
import UIKit
@testable import magic_hat

@Suite("Scanning")
struct ScanTests {
    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.4, h: CGFloat = 0.04, confidence: Float = 0.9) -> RecognizedLine {
        RecognizedLine(text: text, confidence: confidence, box: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func readsTitleAndInfoBlock() {
        let lines = [
            line("Lightning Bolt ®", x: 0.07, y: 0.90),
            line("Instant", x: 0.07, y: 0.42),
            line("Lightning Bolt deals 3 damage to any target.", x: 0.07, y: 0.30, w: 0.8),
            line("0141/0280 C", x: 0.05, y: 0.045, w: 0.25, h: 0.02),
            line("M11 • EN", x: 0.05, y: 0.02, w: 0.2, h: 0.02),
            line("Illus. Christopher Moeller", x: 0.3, y: 0.03, w: 0.5, h: 0.02),
        ]
        let reading = CardTextReader.read(lines, knownSets: ["m11", "dsk"])
        #expect(reading.name == "Lightning Bolt")
        #expect(reading.setCode == "m11")
        #expect(reading.collectorNumber == "141")
    }

    @Test func aStrayWordIsNotASetAndANumberAloneFindsNothing() {
        let lines = [
            line("Sol Ring", x: 0.07, y: 0.9),
            line("0123 R", x: 0.05, y: 0.04, w: 0.2, h: 0.02),
            line("FOIL THE • EN", x: 0.05, y: 0.02, w: 0.2, h: 0.02),
        ]
        let reading = CardTextReader.read(lines, knownSets: ["m11"])
        #expect(reading.name == "Sol Ring" && reading.setCode == nil && reading.collectorNumber == nil)
    }

    @Test func titleCleaning() {
        #expect(CardTextReader.cleanTitle("Sol Ring 1") == "Sol Ring")
        #expect(CardTextReader.cleanTitle("Jace, the Mind Sculptor 2U U") == "Jace, the Mind Sculptor")
        #expect(CardTextReader.cleanTitle("Urza’s Saga") == "Urza's Saga")
        #expect(CardTextReader.collectorNumber(in: "045/280 U") == "45")
        #expect(CardTextReader.collectorNumber(in: "0217a") == "217a")
    }

    @Test func similarityAndConfidence() {
        #expect(CardTextReader.similarity("Lightning Bolt", "lightning bolt") == 1)
        #expect(CardTextReader.similarity("Lightnlng Bolt", "Lightning Bolt") > 0.9)
        #expect(CardTextReader.similarity("Delver of Secrets", "Delver of Secrets // Insectile Aberration") == 1)
        #expect(ScanMatcher.confidence(read: "Lightnlng Bolt", found: "Lightning Bolt", exactPrinting: false) == .sure)
        #expect(ScanMatcher.confidence(read: "Lightning Blast", found: "Lightning Bolt", exactPrinting: false) == .unsure)
        #expect(ScanMatcher.confidence(read: "Forest", found: "Lightning Bolt", exactPrinting: true) == nil,
                "a misread number that lands on another card is thrown out")
        #expect(ScanMatcher.confidence(read: nil, found: "Lightning Bolt", exactPrinting: true) == .unsure, "no title read: ask")
    }

    @Test func guideMapsThroughAspectFill() {
        // A 390×844 view over a 1080×1920 upright image: scaled to cover
        // the height, cropped left and right.
        let view = CGSize(width: 390, height: 844)
        let image = CGSize(width: 1080, height: 1920)
        let full = CardCamera.guideRegion(guide: CGRect(origin: .zero, size: view), in: view, imageSize: image)
        #expect(abs(full.height - 1) < 0.001 && full.width < 1 && abs(full.midX - 0.5) < 0.001)
        let top = CardCamera.guideRegion(guide: CGRect(x: 0, y: 0, width: 390, height: 100), in: view, imageSize: image)
        #expect(top.minY > 0.8, "Vision's origin is the bottom left: \(top)")
        #expect(CardCamera.orientation(forAngle: 90) == .right && CardCamera.orientation(forAngle: 0) == .up)
    }

    /// Vision itself, on a drawn card: the reader finds the name and the
    /// printing the way it would through the camera.
    @Test func visionReadsADrawnCard() throws {
        let size = CGSize(width: 630, height: 880)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor.black]
            ("Lightning Bolt" as NSString).draw(at: CGPoint(x: 44, y: 40), withAttributes: title)
            let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: UIColor.black]
            ("0141/0280 C" as NSString).draw(at: CGPoint(x: 34, y: 812), withAttributes: small)
            ("M11 • EN" as NSString).draw(at: CGPoint(x: 34, y: 842), withAttributes: small)
        }
        let frame = CardCamera.recognizeFrame(image: image)
        #expect(frame.layout == .card, "a photo cropped to the card is the card")
        let reading = CardTextReader.read(frame.lines, knownSets: ["m11"], layout: frame.layout)
        #expect(reading.name == "Lightning Bolt", "\(frame.lines.map(\.text))")
        #expect(reading.setCode == "m11" && reading.collectorNumber == "141", "\(frame.lines.map { "\($0.text) \($0.box)" })")
    }

    /// A card drawn small and off-centre on a dark table, `scale` of the
    /// picture's height.
    private func table(cardHeight scale: CGFloat, at origin: CGPoint, border: UIColor = .white, ink: UIColor = .black) -> UIImage {
        let size = CGSize(width: 1080, height: 1920)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let h = size.height * scale, w = h * 63 / 88
            let card = CGRect(x: origin.x * size.width, y: origin.y * size.height, width: w, height: h)
            border.setFill()
            UIBezierPath(roundedRect: card, cornerRadius: w * 0.04).fill()
            let unit = h / 880
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 38 * unit), .foregroundColor: ink]
            ("Lightning Bolt" as NSString).draw(at: CGPoint(x: card.minX + 44 * unit, y: card.minY + 40 * unit), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26 * unit), .foregroundColor: ink]
            ("Instant" as NSString).draw(at: CGPoint(x: card.minX + 44 * unit, y: card.minY + 500 * unit), withAttributes: body)
            ("Lightning Bolt deals 3 damage" as NSString).draw(at: CGPoint(x: card.minX + 44 * unit, y: card.minY + 560 * unit), withAttributes: body)
            let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20 * unit, weight: .semibold), .foregroundColor: ink]
            ("0141/0280 C" as NSString).draw(at: CGPoint(x: card.minX + 34 * unit, y: card.minY + 812 * unit), withAttributes: small)
            ("M11 • EN" as NSString).draw(at: CGPoint(x: card.minX + 34 * unit, y: card.minY + 842 * unit), withAttributes: small)
        }
    }

    /// No frame to hold the card in: it is found in the picture, at
    /// whatever size and place, and read as if it filled a guide.
    @Test func aCardAnywhereInThePictureIsFoundAndRead() throws {
        for (scale, origin) in [(0.55, CGPoint(x: 0.12, y: 0.2)), (0.4, CGPoint(x: 0.4, y: 0.45)), (0.7, CGPoint(x: 0.05, y: 0.08))] {
            let image = table(cardHeight: scale, at: origin)
            let ci = try #require(CIImage(image: image))
            // Part of the picture is off screen, as the preview's crop is.
            let visible = CGRect(x: 0.03, y: 0, width: 0.94, height: 1)
            let frame = CardCamera.recognizeFrame(ci, orientation: .up, visible: visible)
            let card = try #require(frame.card, "the rectangle detector finds the card at \(scale)")
            #expect(frame.layout == .card)
            #expect(abs(card.height - scale) < 0.06 && abs(card.minX - origin.x) < 0.04, "\(card)")
            #expect(abs((1 - card.maxY) - origin.y) < 0.04, "Vision's origin is the bottom left: \(card)")
            let reading = CardTextReader.read(frame.lines, knownSets: ["m11"], layout: frame.layout)
            #expect(reading.name == "Lightning Bolt", "\(scale): \(frame.lines.map(\.text))")
            #expect(reading.setCode == "m11" && reading.collectorNumber == "141", "\(scale): \(frame.lines.map { "\($0.text) \($0.box)" })")
        }
    }

    /// No edges to find (the card's border is the table's colour): the
    /// text alone places the title and the info block.
    @Test func aCardWithNoEdgesIsReadFromItsText() throws {
        let image = table(cardHeight: 0.55, at: CGPoint(x: 0.2, y: 0.2), border: UIColor(white: 0.12, alpha: 1), ink: .white)
        let ci = try #require(CIImage(image: image))
        let frame = CardCamera.recognizeFrame(ci, orientation: .up, visible: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(frame.card == nil && frame.layout == .picture)
        let reading = CardTextReader.read(frame.lines, knownSets: ["m11"], layout: frame.layout)
        #expect(reading.name == "Lightning Bolt", "\(frame.lines.map(\.text))")
        #expect(reading.setCode == "m11" && reading.collectorNumber == "141", "\(frame.lines.map { "\($0.text) \($0.box)" })")
    }

    @Test func thePictureLayoutFindsTheBlockByWhatItSays() {
        // A card low and right in the picture, another card's title above it.
        let lines = [
            line("Some Other Card", x: 0.05, y: 0.93, w: 0.3, h: 0.02),
            line("Lightning Bolt", x: 0.52, y: 0.60, w: 0.2, h: 0.018),
            line("Instant", x: 0.52, y: 0.40, w: 0.1, h: 0.012),
            line("ONE with the storm, deal 3 damage.", x: 0.52, y: 0.33, w: 0.3, h: 0.012),
            line("0141/0280 C", x: 0.51, y: 0.222, w: 0.08, h: 0.008),
            line("M11 • EN", x: 0.51, y: 0.21, w: 0.06, h: 0.008),
        ]
        let reading = CardTextReader.read(lines, knownSets: ["m11", "one"], layout: .picture)
        #expect(reading.name == "Lightning Bolt", "the title over the info block, not the topmost text in the picture")
        #expect(reading.setCode == "m11" && reading.collectorNumber == "141" && reading.language == "en" && reading.foil == false)
        let bare = CardTextReader.read(Array(lines.prefix(3)), knownSets: ["m11"], layout: .picture)
        #expect(bare.name == "Some Other Card" && bare.setCode == nil, "no block: the topmost name")
        let back = CardCamera.viewRect(region: CardCamera.guideRegion(guide: CGRect(x: 40, y: 100, width: 200, height: 280),
                                                                         in: CGSize(width: 390, height: 844), imageSize: CGSize(width: 1080, height: 1920)),
                                       in: CGSize(width: 390, height: 844), imageSize: CGSize(width: 1080, height: 1920))
        #expect(abs(back.minX - 40) < 0.5 && abs(back.minY - 100) < 0.5 && abs(back.width - 200) < 0.5 && abs(back.height - 280) < 0.5)
    }
}
