//
//  PriceHistory.swift
//  magic-hat
//
//  What a card has been worth, day by day, kept on the phone: Scryfall
//  publishes one market price per finish and no history, and the sources
//  that do (MTGJSON's AllPrices, 90 days per card) ship as a file far too
//  big to read on a device. So the app keeps its own: every time a price
//  lands for an owned card — the 6h/12h/daily refresh, a hydration, the
//  weekly catalog ingest — `CardMetaWriter` records the day's prices. The
//  record starts the day the card is first owned; nothing is backfilled.
//
//  One row per printing (`PriceHistory`), its samples packed in a blob:
//  18 bytes a day — the day as days since 2020-01-01, then USD, USD foil,
//  EUR, EUR foil as Float32, NaN for a price Scryfall didn't have — so a
//  card's whole year is 6.5KB and a 3,900-card collection's a few MB.
//  `PriceSeries` is the pure value the blob encodes, with the reads the
//  chart needs; `PriceHistoryTests` covers it.
//

import Foundation
import SwiftData

/// One day's prices for a printing.
nonisolated struct PriceSample: Hashable, Sendable, Codable {
    /// Days since 2020-01-01, UTC.
    var day: Int
    var usd: Double?
    var usdFoil: Double?
    var eur: Double?
    var eurFoil: Double?

    static let epoch: Date = {
        var c = DateComponents(); c.year = 2020; c.month = 1; c.day = 1
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()

    static func day(of date: Date) -> Int { Int(floor(date.timeIntervalSince(epoch) / 86_400)) }
    static func date(of day: Int) -> Date { epoch.addingTimeInterval(Double(day) * 86_400) }

    var date: Date { Self.date(of: day) }

    func price(foil: Bool, in currency: DisplayCurrency) -> Double? {
        switch currency {
        case .usd: return foil ? (usdFoil ?? usd) : usd
        case .eur: return foil ? (eurFoil ?? eur) : eur
        }
    }

    var isEmpty: Bool { usd == nil && usdFoil == nil && eur == nil && eurFoil == nil }
}

/// A printing's samples, oldest first, one per day.
nonisolated struct PriceSeries: Hashable, Sendable {
    private(set) var samples: [PriceSample] = []

    init(samples: [PriceSample] = []) {
        self.samples = samples.sorted { $0.day < $1.day }
    }

    var isEmpty: Bool { samples.isEmpty }
    var count: Int { samples.count }
    var first: PriceSample? { samples.first }
    var last: PriceSample? { samples.last }

    /// Records the day's prices: a sample for the same day is replaced
    /// (the refresh runs several times a day), an empty one is ignored.
    /// Returns whether anything changed.
    @discardableResult
    mutating func record(_ sample: PriceSample) -> Bool {
        guard !sample.isEmpty else { return false }
        // Stored as Float32: hold the same precision in memory, so a
        // series compares equal to itself read back.
        var sample = sample
        sample.usd = sample.usd.map { Double(Float($0)) }
        sample.usdFoil = sample.usdFoil.map { Double(Float($0)) }
        sample.eur = sample.eur.map { Double(Float($0)) }
        sample.eurFoil = sample.eurFoil.map { Double(Float($0)) }
        if let i = samples.firstIndex(where: { $0.day == sample.day }) {
            guard samples[i] != sample else { return false }
            samples[i] = sample
            return true
        }
        if let i = samples.firstIndex(where: { $0.day > sample.day }) { samples.insert(sample, at: i) } else { samples.append(sample) }
        return true
    }

    /// The points for one finish in one currency, days without that price
    /// left out.
    func points(foil: Bool, currency: DisplayCurrency) -> [(date: Date, price: Double)] {
        samples.compactMap { s in s.price(foil: foil, in: currency).map { (s.date, $0) } }
    }

    /// The change from the sample on or before `days` ago to the latest:
    /// nil until there are two days to compare.
    func change(over days: Int, foil: Bool, currency: DisplayCurrency, now: Date = Date()) -> (amount: Double, percent: Double)? {
        let pts = points(foil: foil, currency: currency)
        guard let latest = pts.last, pts.count > 1 else { return nil }
        let cutoff = PriceSample.day(of: now) - days
        let base = pts.last { PriceSample.day(of: $0.date) <= cutoff } ?? pts.first!
        guard base.date != latest.date, base.price > 0 else { return nil }
        let diff = latest.price - base.price
        return (diff, diff / base.price * 100)
    }

    // MARK: Packing

    static let recordSize = 18

    var packed: Data {
        var data = Data(capacity: samples.count * Self.recordSize)
        for s in samples {
            var day = UInt16(clamping: max(0, s.day)).littleEndian
            withUnsafeBytes(of: &day) { data.append(contentsOf: $0) }
            for v in [s.usd, s.usdFoil, s.eur, s.eurFoil] {
                var f = Float(v ?? .nan).bitPattern.littleEndian
                withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    init(packed data: Data) {
        var out: [PriceSample] = []
        out.reserveCapacity(data.count / Self.recordSize)
        var offset = 0
        while offset + Self.recordSize <= data.count {
            let day = Int(UInt16(littleEndian: data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }))
            var values: [Double?] = []
            for i in 0..<4 {
                let start = offset + 2 + i * 4
                let bits = UInt32(littleEndian: data.subdata(in: start..<(start + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                let f = Float(bitPattern: bits)
                values.append(f.isNaN ? nil : Double(f))
            }
            out.append(PriceSample(day: day, usd: values[0], usdFoil: values[1], eur: values[2], eurFoil: values[3]))
            offset += Self.recordSize
        }
        self.init(samples: out)
    }
}

/// A printing's price history row: the blob, and the latest day for a
/// cheap "already sampled today" check.
@Model
nonisolated final class PriceHistory {
    @Attribute(.unique) var scryfallID: String
    var samplesData: Data
    var lastDay: Int

    init(scryfallID: String, series: PriceSeries = PriceSeries()) {
        self.scryfallID = scryfallID
        self.samplesData = series.packed
        self.lastDay = series.last?.day ?? -1
    }

    var series: PriceSeries {
        get { PriceSeries(packed: samplesData) }
        set { samplesData = newValue.packed; lastDay = newValue.last?.day ?? -1 }
    }
}

nonisolated extension PriceSample {
    /// Today's sample from a card's metadata as just written.
    init(meta: CardMeta, day: Int = PriceSample.day(of: Date())) {
        self.init(day: day, usd: meta.priceUSD, usdFoil: meta.priceUSDFoil, eur: meta.priceEUR, eurFoil: meta.priceEURFoil)
    }
}
