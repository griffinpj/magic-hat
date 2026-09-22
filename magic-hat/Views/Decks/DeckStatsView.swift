//
//  DeckStatsView.swift
//  magic-hat
//
//  The Stats tab: how the deck is doing (size, value, what's built, what's
//  missing, problems), then the shape of it — mana curve by colour, colour
//  pips, what the mana base produces, card types, rarities. Swift Charts,
//  Mana's pip palette, everything from the DeckStats computed off-main.
//

import SwiftUI
import Charts

struct DeckStatsView: View {
    let snapshot: DeckSnapshot

    @State private var includeGeneric = false

    private var stats: DeckStats { snapshot.stats }

    var body: some View {
        List {
            overview
            if !stats.issues.isEmpty { issues }
            curve
            pips
            production
            types
            if !stats.rarities.isEmpty { rarities }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Overview

    private var overview: some View {
        Section("Overview") {
            if let target = stats.target {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Cards", value: "\(stats.copies) / \(target)")
                    ProgressView(value: Double(min(stats.copies, target)), total: Double(target))
                        .tint(stats.copies == target ? .green : .accentColor)
                }
            } else {
                LabeledContent("Cards", value: "\(stats.copies)")
            }
            LabeledContent("Lands", value: "\(stats.landCopies)")
            LabeledContent("Average mana value", value: String(format: "%.2f", stats.averageManaValue))
            LabeledContent("Median mana value", value: String(format: "%.1f", stats.medianManaValue))
            LabeledContent("Value", value: PriceFormat.compact(stats.totalValue))
            ownership
        }
    }

    private var ownership: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                stat("In deck", stats.builtCopies, .green)
                stat("In collection", stats.availableCopies, .blue)
                stat("Missing", stats.missingCopies, .red)
            }
            if stats.missingCopies > 0 {
                Text("Missing cards would cost about \(PriceFormat.compact(stats.missingValue)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var issues: some View {
        Section("Check") {
            ForEach(stats.issues) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Curve

    private struct CurveSegment: Identifiable {
        let bucket: String
        let colorClass: String
        let count: Int
        var id: String { bucket + colorClass }
    }

    private struct CurveTotal: Identifiable {
        let bucket: String
        let total: Int
        var id: String { bucket }
    }

    private var curveSegments: [CurveSegment] {
        stats.curve.flatMap { bar in
            Self.classOrder.compactMap { cls in
                guard let n = bar.counts[cls], n > 0 else { return nil }
                return CurveSegment(bucket: bar.label, colorClass: cls.label, count: n)
            }
        }
    }

    private var curveTotals: [CurveTotal] {
        stats.curve.filter { $0.total > 0 }.map { CurveTotal(bucket: $0.label, total: $0.total) }
    }

    private var curve: some View {
        let segments = curveSegments
        let totals = curveTotals
        return Section("Mana Value") {
            Chart {
                ForEach(segments) { segment in
                    BarMark(x: .value("Mana value", segment.bucket), y: .value("Cards", segment.count))
                        .foregroundStyle(by: .value("Color", segment.colorClass))
                }
                ForEach(totals) { total in
                    PointMark(x: .value("Mana value", total.bucket), y: .value("Cards", total.total))
                        .opacity(0)
                        .annotation(position: .top, spacing: 2) {
                            Text("\(total.total)").font(.caption2.weight(.semibold)).monospacedDigit()
                        }
                }
            }
            .chartXScale(domain: stats.curve.map(\.label))
            .chartForegroundStyleScale(domain: Self.classOrder.map(\.label), range: Self.classOrder.map(Self.color))
            .chartLegend(position: .bottom, spacing: 8)
            .chartYAxis(.hidden)
            .frame(height: 220)
            .padding(.vertical, 4)
            .accessibilityLabel("Mana curve: " + totals.map { "\($0.bucket): \($0.total)" }.joined(separator: ", "))
        }
    }

    private static let classOrder: [ColorClass] = [.white, .blue, .black, .red, .green, .multicolor, .colorless]

    private static func color(_ cls: ColorClass) -> Color {
        switch cls {
        case .multicolor: return Color(red: 0.85, green: 0.72, blue: 0.35)
        case .colorless: return ManaPalette.generic
        default: return ManaColor(rawValue: cls.rawValue).map(ManaPalette.color) ?? .gray
        }
    }

    // MARK: Pips

    private var pips: some View {
        Section {
            pie(colors: stats.pips, colorless: includeGeneric ? stats.genericPips : 0, colorlessLabel: "Generic")
            Toggle("Include generic mana", isOn: $includeGeneric)
        } header: {
            Text("Mana Symbols")
        } footer: {
            Text("Coloured pips across every mana cost; hybrids count for each colour.")
        }
    }

    private var production: some View {
        Section {
            if stats.production.isEmpty && stats.colorlessProduction == 0 {
                Text("No mana producers yet.").foregroundStyle(.secondary)
            } else {
                pie(colors: stats.production, colorless: stats.colorlessProduction, colorlessLabel: "Colorless")
            }
        } header: {
            Text("Mana Production")
        } footer: {
            Text("Lands and permanents that add mana, by the colours they can make.")
        }
    }

    private struct Slice: Identifiable {
        let label: String
        let count: Int
        let color: Color
        var id: String { label }
    }

    private func pie(colors: [ManaColor: Int], colorless: Int, colorlessLabel: String) -> some View {
        var slices = ManaColor.allCases.compactMap { color -> Slice? in
            guard let n = colors[color], n > 0 else { return nil }
            return Slice(label: color.name, count: n, color: ManaPalette.color(color))
        }
        if colorless > 0 { slices.append(Slice(label: colorlessLabel, count: colorless, color: ManaPalette.generic)) }
        let total = slices.reduce(0) { $0 + $1.count }
        return HStack(spacing: 16) {
            Chart(slices) { slice in
                SectorMark(angle: .value(slice.label, slice.count), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(slice.color)
                    .cornerRadius(3)
            }
            .frame(width: 140, height: 140)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(slices) { slice in
                    HStack(spacing: 8) {
                        Circle().fill(slice.color).frame(width: 10, height: 10)
                        Text(slice.label)
                        Spacer()
                        Text("\(slice.count)").monospacedDigit().foregroundStyle(.secondary)
                        if total > 0 {
                            Text("\(Int((Double(slice.count) / Double(total) * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing)
                        }
                    }
                    .font(.subheadline)
                }
                if slices.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Types / rarities

    private var types: some View {
        Section("Card Types") {
            Chart(stats.types) { type in
                BarMark(x: .value("Cards", type.count), y: .value("Type", type.name))
                    .foregroundStyle(Color.accentColor.gradient)
                    .annotation(position: .trailing, spacing: 4) {
                        Text("\(type.count)").font(.caption2).monospacedDigit()
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(1, stats.types.count)) * 28 + 16)
            .padding(.vertical, 4)
        }
    }

    private var rarities: some View {
        Section("Rarity") {
            HStack(spacing: 12) {
                ForEach(stats.rarities) { r in
                    VStack(spacing: 2) {
                        Text("\(r.count)").font(.headline).monospacedDigit()
                        Text(r.name).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
