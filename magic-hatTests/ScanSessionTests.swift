import Testing
import Foundation
import CoreGraphics
@testable import magic_hat

/// The scanner's tray: a card is counted once, a different printing is a
/// different card, and the overlay's edits land on the card just scanned.
@MainActor
@Suite("Scan session", .serialized)
struct ScanSessionTests {
    static func card(_ id: String, _ name: String, set: String, number: String, usd: String? = "2.00", foil: String? = "5.00",
                     finishes: [String] = ["nonfoil", "foil"], promo: Bool = false) throws -> ScryfallCard {
        var json: [String: Any] = [
            "id": id, "oracle_id": "o-\(name)", "name": name, "set": set, "set_name": set.uppercased(),
            "collector_number": number, "rarity": "rare", "finishes": finishes, "promo": promo, "lang": "en",
        ]
        var prices: [String: Any] = [:]
        if let usd { prices["usd"] = usd }
        if let foil { prices["usd_foil"] = foil }
        json["prices"] = prices
        return try JSONDecoder().decode(ScryfallCard.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func withDefaults(_ body: (ScanSession) throws -> Void) rethrows {
        let settings = ScanSettings.shared
        let saved = (settings.preferFoil, settings.quickMode, settings.ignoreLowValues)
        defer { settings.preferFoil = saved.0; settings.quickMode = saved.1; settings.ignoreLowValues = saved.2 }
        settings.preferFoil = false
        settings.quickMode = true
        settings.ignoreLowValues = false
        try body(ScanSession(settings: settings))
    }

    @Test func theSamePrintingIsCountedOnce() throws {
        try withDefaults { session in
            let bolt = try Self.card("b1", "Lightning Bolt", set: "m11", number: "146")
            session.accept(bolt, exactPrinting: true, reading: nil)
            session.accept(bolt, exactPrinting: true, reading: nil)
            #expect(session.tray.count == 1 && session.trayCopies == 1, "a second read of the same card adds nothing")
            #expect(session.phase == .again(CardItem(scryfallCard: bolt, owned: false)))
            session.incrementCurrent()
            #expect(session.trayCopies == 2, "+1 is how another copy goes in")

            let otherPrinting = try Self.card("b2", "Lightning Bolt", set: "2xm", number: "129")
            session.accept(otherPrinting, exactPrinting: true, reading: nil)
            #expect(session.tray.count == 2, "another printing is another card")
            #expect(session.current?.printing.setCode == "2xm")
        }
    }

    @Test func aReadOfTheLastCardIsIgnoredUnlessItsPrintingDiffers() {
        let last = (name: "Lightning Bolt", printingKey: Optional("m11|146"))
        var reading = ScanReading(name: "Lightning Bolt")
        #expect(ScanSession.isSameAsLast(reading, last: last), "the name alone: the same card, held again")
        reading.setCode = "m11"; reading.collectorNumber = "146"
        #expect(ScanSession.isSameAsLast(reading, last: last))
        reading.setCode = "2xm"; reading.collectorNumber = "129"
        #expect(!ScanSession.isSameAsLast(reading, last: last), "a different printing read off the card")
        #expect(!ScanSession.isSameAsLast(ScanReading(name: "Counterspell"), last: last))
    }

    @Test func overlayEditsTheCurrentCard() throws {
        try withDefaults { session in
            let card = try Self.card("c1", "Sol Ring", set: "c21", number: "263", usd: "1.50", foil: "4.00")
            session.accept(card, exactPrinting: false, reading: nil)
            #expect(session.current?.finish == .normal && session.current?.language == AppSettings.cardLanguage)
            session.setCurrentFinish(.foil)
            session.setCurrentLanguage("ja")
            session.incrementCurrent()
            #expect(session.current?.finish == .foil && session.current?.language == "ja" && session.current?.quantity == 2)
            #expect(session.totalValue == 8)
            let other = try Self.card("c2", "Sol Ring", set: "cmm", number: "410", finishes: ["nonfoil"])
            session.setCurrentPrinting(other)
            #expect(session.current?.printing.setCode == "cmm" && session.current?.finish == .normal,
                    "a printing with no foil drops the foil")
            #expect(session.current?.exactPrinting == true)
            session.decrementCurrent(); session.decrementCurrent()
            #expect(session.tray.isEmpty)
        }
    }

    @Test func readFoilAndPreferFoilAndLowValues() throws {
        try withDefaults { session in
            var reading = ScanReading(name: "Sol Ring")
            reading.foil = true
            reading.language = "de"
            session.accept(try Self.card("f1", "Sol Ring", set: "c21", number: "263"), exactPrinting: true, reading: reading)
            #expect(session.current?.finish == .foil && session.current?.language == "de", "the ★ in the corner is foil")

            session.settings.preferFoil = true
            session.accept(try Self.card("f2", "Opt", set: "dom", number: "60", usd: "0.10", foil: "0.50"), exactPrinting: true, reading: nil)
            #expect(session.current?.finish == .foil)
            session.accept(try Self.card("f3", "Island", set: "dsk", number: "277", finishes: ["nonfoil"]), exactPrinting: true, reading: nil)
            #expect(session.current?.finish == .normal, "no foil printing: stays normal")

            let all = session.totalValue
            session.settings.ignoreLowValues = true
            #expect(session.totalValue == all - 0.5, "the $0.50 Opt leaves the total")
        }
    }

    @Test func infoLineFoilAndLanguage() {
        #expect(CardTextReader.foilMark(in: "DSK ★ EN", after: "dsk") == true)
        #expect(CardTextReader.foilMark(in: "DSK • EN", after: "dsk") == false)
        #expect(CardTextReader.foilMark(in: "DSK EN", after: "dsk") == nil)
        #expect(CardTextReader.language(in: "DSK • JP", after: "dsk") == "ja")
        #expect(CardTextReader.language(in: "MOM * DE", after: "mom") == "de")
        let lines = [
            RecognizedLine(text: "Lightning Bolt", confidence: 0.9, box: CGRect(x: 0.07, y: 0.9, width: 0.4, height: 0.04)),
            RecognizedLine(text: "0141/0280 C", confidence: 0.9, box: CGRect(x: 0.05, y: 0.045, width: 0.25, height: 0.02)),
            RecognizedLine(text: "M11 ★ FR", confidence: 0.9, box: CGRect(x: 0.05, y: 0.02, width: 0.2, height: 0.02)),
        ]
        let reading = CardTextReader.read(lines, knownSets: ["m11"])
        #expect(reading.foil == true && reading.language == "fr" && reading.setCode == "m11")
    }

    @Test func printingQueryNarrowsOnlyWhenSomethingSays() {
        let none = ScanMatchOptions()
        #expect(ScanMatcher.printingQuery(name: "Sol Ring", reading: ScanReading(name: "Sol Ring"), options: none,
                                          currentSet: "c21", currentPromo: false) == nil)
        var byNumber = ScanReading(name: "Sol Ring"); byNumber.collectorNumber = "263"
        #expect(ScanMatcher.printingQuery(name: "Sol Ring", reading: byNumber, options: none, currentSet: "c21", currentPromo: false)
                == "!\"Sol Ring\" cn:263")
        let locked = ScanMatchOptions(lockedSets: ["cmm", "c21"], ignorePromos: true)
        #expect(ScanMatcher.printingQuery(name: "Sol Ring", reading: ScanReading(name: "Sol Ring"), options: locked,
                                          currentSet: "sld", currentPromo: true) == "!\"Sol Ring\" (s:c21 or s:cmm) -is:promo")
        #expect(ScanMatcher.printingQuery(name: "Sol Ring", reading: ScanReading(name: "Sol Ring"), options: locked,
                                          currentSet: "c21", currentPromo: false) == nil, "already in a locked set")
    }
}
