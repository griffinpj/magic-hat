//
//  CardPriceHistoryView.swift
//  magic-hat
//
//  A card's price over time, from the viewer's price line (tap it):
//  Stocks' shape — the price large, the change over the range beside it
//  in the direction's colour, a range picker (1M, 3M, 1Y, All), a line
//  with a soft fill, a finger on the chart reading one day — over the
//  samples the app has recorded itself (see PriceHistory). The first
//  day a card is owned is the first point, so a new collection's charts
//  start as a dot and say so, honestly, rather than inventing a curve.
//

import SwiftUI
import SwiftData
import Charts

struct CardPriceHistoryView: View {
    let item: CardItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var series: PriceSeries?
    @State private var range: Range = .threeMonths
    @State private var foil: Bool
    @State private var selectedDate: Date?

    private let currency = AppSettings.currency

    enum Range: String, CaseIterable, Identifiable {
        case month = "1M", threeMonths = "3M", year = "1Y", all = "All"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .month: return 30
            case .threeMonths: return 91
            case .year: return 365
            case .all: return nil
            }
        }
    }

    init(item: CardItem) {
        self.item = item
        _foil = State(initialValue: item.finish != .normal)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let series {
                    content(series)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("price-history-done")
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Content

    private var hasFoilPrices: Bool {
        guard let series else { return item.priceFoil != nil }
        return !series.points(foil: true, currency: currency).isEmpty && item.priceFoil != nil
    }

    private func visiblePoints(_ series: PriceSeries) -> [(date: Date, price: Double)] {
        let all = series.points(foil: foil, currency: currency)
        guard let days = range.days else { return all }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let inRange = all.filter { $0.date >= cutoff }
        // Keep the last point before the range so the line enters from
        // the left rather than starting mid-chart.
        if let before = all.last(where: { $0.date < cutoff }), !inRange.isEmpty { return [before] + inRange }
        return inRange
    }

    private func content(_ series: PriceSeries) -> some View {
        let points = visiblePoints(series)
        let latest = points.last?.price ?? item.marketPrice
        let change = range.days.map { series.change(over: $0, foil: foil, currency: currency) }
            ?? series.change(over: 100_000, foil: foil, currency: currency)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(latest: latest, change: change, points: points)
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("price-history-range")
                chart(points)
                    .frame(height: 220)
                if hasFoilPrices {
                    Picker("Finish", selection: $foil) {
                        Text("Nonfoil").tag(false)
                        Text("Foil").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("price-history-finish")
                }
                footer(series)
            }
            .padding(16)
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .onChange(of: foil) { _, _ in selectedDate = nil }
    }

    /// The price in large type and the change over the range; with a
    /// finger on the chart, that day's price and date instead.
    private func header(latest: Double?, change: (amount: Double, percent: Double)?, points: [(date: Date, price: Double)]) -> some View {
        let selected = selectedDate.flatMap { date in points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(PriceFormat.string(selected?.price ?? latest, currency: currency))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("price-history-price")
                if selected == nil, let change, change.amount != 0 {
                    let up = change.amount > 0
                    Text("\(PriceFormat.signed(change.amount, currency: currency)) (\(PriceFormat.percent(change.percent)))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(up ? .green : .red)
                        .accessibilityIdentifier("price-history-change")
                }
            }
            Text(selected.map { $0.date.formatted(date: .long, time: .omitted) }
                 ?? (foil ? "Foil market price" : "Market price") + " · " + rangeLabel(change: change))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .animation(.snappy(duration: 0.2), value: selected?.date)
    }

    private func rangeLabel(change: (amount: Double, percent: Double)?) -> String {
        switch range {
        case .month: return change == nil ? "past month" : "change over a month"
        case .threeMonths: return change == nil ? "past three months" : "change over three months"
        case .year: return change == nil ? "past year" : "change over a year"
        case .all: return change == nil ? "all recorded" : "change since the first record"
        }
    }

    @ViewBuilder private func chart(_ points: [(date: Date, price: Double)]) -> some View {
        if points.count < 2 {
            ContentUnavailableView {
                Label("Price History Starts Here", systemImage: "chart.line.uptrend.xyaxis")
            } description: {
                Text(points.isEmpty
                     ? "No price has been recorded for this printing yet. The app records one each time prices refresh."
                     : "One day recorded so far. The line draws itself as prices refresh — every 6 hours by default.")
            }
            .frame(maxWidth: .infinity)
        } else {
            let up = (points.last?.price ?? 0) >= (points.first?.price ?? 0)
            let tint: Color = up ? .green : .red
            let low = points.map(\.price).min() ?? 0
            let high = points.map(\.price).max() ?? 1
            let pad = max((high - low) * 0.15, 0.05)
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("Day", p.date), yStart: .value("Floor", max(0, low - pad)), yEnd: .value("Price", p.price))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", p.date), y: .value("Price", p.price))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let selectedDate, let p = points.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
                    RuleMark(x: .value("Day", p.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Day", p.date), y: .value("Price", p.price))
                        .foregroundStyle(tint)
                        .symbolSize(60)
                }
            }
            .chartYScale(domain: max(0, low - pad)...(high + pad))
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(PriceFormat.compact(v, currency: currency)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), collisionResolution: .greedy)
                }
            }
            .chartXSelection(value: $selectedDate)
            .accessibilityIdentifier("price-history-chart")
            .accessibilityLabel("Price chart, \(points.count) days")
        }
    }

    private func footer(_ series: PriceSeries) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let first = series.first {
                Text("\(series.count == 1 ? "1 day" : "\(series.count) days") recorded since \(first.date.formatted(date: .abbreviated, time: .omitted)).")
            }
            Text("Prices are Scryfall's market price, recorded on this phone each time they refresh. Nothing before the card was owned is known.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        let store = CollectionStore.shared(for: modelContext.container)
        var loaded = (try? await store.priceHistory(scryfallID: item.scryfallID)) ?? PriceSeries()
        // Today's price is on the card already; show it even before the
        // writer has recorded the day.
        if loaded.last?.day != PriceSample.day(of: Date()) {
            loaded.record(PriceSample(day: PriceSample.day(of: Date()),
                                      usd: currency == .usd ? item.price : nil, usdFoil: currency == .usd ? item.priceFoil : nil,
                                      eur: currency == .eur ? item.price : nil, eurFoil: currency == .eur ? item.priceFoil : nil))
        }
        series = loaded
    }
}
