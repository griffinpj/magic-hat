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
        let lines = CardCamera.recognize(image: image)
        let reading = CardTextReader.read(lines, knownSets: ["m11"])
        #expect(reading.name == "Lightning Bolt", "\(lines.map(\.text))")
        #expect(reading.setCode == "m11" && reading.collectorNumber == "141", "\(lines.map { "\($0.text) \($0.box)" })")
    }
}
