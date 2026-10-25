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
        let sample = sample.quantized
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
        for s in samples { Self.append(s, to: &data) }
        return data
    }

    /// One sample's 18 bytes onto the end of a blob.
    static func append(_ s: PriceSample, to data: inout Data) {
        var day = UInt16(clamping: max(0, s.day)).littleEndian
        withUnsafeBytes(of: &day) { data.append(contentsOf: $0) }
        for v in [s.usd, s.usdFoil, s.eur, s.eurFoil] {
            var f = Float(v ?? .nan).bitPattern.littleEndian
            withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        }
    }

    /// The sample at `offset` of a packed buffer.
    static func sample(in raw: UnsafeRawBufferPointer, at offset: Int) -> PriceSample {
        func value(_ i: Int) -> Double? {
            let f = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 2 + i * 4, as: UInt32.self)))
            return f.isNaN ? nil : Double(f)
        }
        let day = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
        return PriceSample(day: day, usd: value(0), usdFoil: value(1), eur: value(2), eurFoil: value(3))
    }

    /// Read in place: five `subdata` copies a sample (a year of a card is
    /// 1,800 allocations) were most of what decoding cost. The blob is
    /// written oldest first, so it isn't sorted again.
    init(packed data: Data) {
        let count = data.count / Self.recordSize
        var out: [PriceSample] = []
        out.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count { out.append(Self.sample(in: raw, at: i * Self.recordSize)) }
        }
        samples = out
    }
}

nonisolated extension PriceSample {
    /// At the precision the blob keeps (Float32), so a series compares
    /// equal to itself read back.
    var quantized: PriceSample {
        var s = self
        s.usd = usd.map { Double(Float($0)) }
        s.usdFoil = usdFoil.map { Double(Float($0)) }
        s.eur = eur.map { Double(Float($0)) }
        s.eurFoil = eurFoil.map { Double(Float($0)) }
        return s
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

    /// `PriceSeries.record` on the blob, without decoding it in the two
    /// cases every refresh is: a new day is 18 bytes appended, today's
    /// again is the last 18 compared and overwritten. Only a day before
    /// the last (a clock moved back) decodes and repacks. Every refresh
    /// batch used to decode and repack every owned series it touched.
    @discardableResult
    func record(_ sample: PriceSample) -> Bool {
        guard !sample.isEmpty else { return false }
        let sample = sample.quantized
        let size = PriceSeries.recordSize
        let tail = samplesData.count - size
        if samplesData.isEmpty || (tail >= 0 && sample.day > lastDay && lastDay >= 0) {
            var data = samplesData
            PriceSeries.append(sample, to: &data)
            samplesData = data
            lastDay = sample.day
            return true
        }
        if tail >= 0, sample.day == lastDay {
            let current = samplesData.withUnsafeBytes { PriceSeries.sample(in: $0, at: tail) }
            guard current != sample else { return false }
            var data = samplesData.prefix(tail)
            PriceSeries.append(sample, to: &data)
            samplesData = data
            return true
        }
        var series = series
        guard series.record(sample) else { return false }
        self.series = series
        return true
    }
}

nonisolated extension PriceSample {
    /// Today's sample from a card's metadata as just written.
    init(meta: CardMeta, day: Int = PriceSample.day(of: Date())) {
        self.init(day: day, usd: meta.priceUSD, usdFoil: meta.priceUSDFoil, eur: meta.priceEUR, eurFoil: meta.priceEURFoil)
    }
}
