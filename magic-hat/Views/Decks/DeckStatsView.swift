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
    /// The deck's analysis, read off-main; nil in previews and tests that
    /// only want the shape.
    var analysis: DeckAnalysisController? = nil
    /// Opens the add sheet on its Recommended scope.
    var onAddRecommended: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var includeGeneric = false

    private var stats: DeckStats { snapshot.stats }

    var body: some View {
        List {
            overview
            // Problems before the analysis: the Cards tab's banner leads here.
            if !stats.issues.isEmpty { issues }
            if let analysis { analysisSection(analysis) }
            curve
            manaCost
            production
            balance
            types
            if !stats.rarities.isEmpty { rarities }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Analysis

    /// The three scores and the bracket at a glance; the full reading and
    /// the recommendations are a push away. Never blank: the local reading
    /// lands in a frame, and the outside signals fill in behind it.
    private func analysisSection(_ controller: DeckAnalysisController) -> some View {
        Section {
            NavigationLink {
                DeckAnalysisView(snapshot: snapshot, controller: controller)
            } label: {
                analysisSummary(controller)
            }
            .accessibilityIdentifier("deck-analysis")
            Button {
                onAddRecommended?()
            } label: {
                HStack {
                    Label("Recommended Cards", systemImage: "wand.and.stars")
                        .foregroundStyle(.primary)
                    Spacer()
                    if let plan = controller.plan {
                        Text("\(plan.recommendations.count)").foregroundStyle(.secondary).monospacedDigit()
                    } else if controller.isPlanning {
                        ProgressView()
                    }
                }
                .contentShape(Rectangle())
            }
            .disabled(snapshot.isLocked)
            .accessibilityIdentifier("deck-recommendations")
            NavigationLink {
                DeckSwapsView(deckID: snapshot.id, controller: controller, context: modelContext)
            } label: {
                HStack {
                    Label("Suggested Swaps", systemImage: "arrow.left.arrow.right")
                    Spacer()
                    if let plan = controller.plan {
                        Text(plan.changeCount == 0 ? "None" : "\(plan.changeCount)").foregroundStyle(.secondary).monospacedDigit()
                    } else if controller.isPlanning {
                        ProgressView()
                    }
                }
            }
            .accessibilityIdentifier("deck-swaps")
        } header: {
            Text("Analysis")
        } footer: {
            Text(controller.sourcesLine)
        }
    }

    @ViewBuilder private func analysisSummary(_ controller: DeckAnalysisController) -> some View {
        if let a = controller.analysis {
            if a.isCommander {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        ScoreGauge(title: "Power", score: a.power, tint: .orange, compact: true)
                        ScoreGauge(title: "Impact", score: a.impact, tint: .red, compact: true)
                        ScoreGauge(title: "Playability", score: a.playability, tint: .green, compact: true)
                    }
                    HStack(spacing: 6) {
                        if let bracket = a.bracket {
                            Text("Bracket \(bracket.level) · \(bracket.name)").font(.subheadline.weight(.medium))
                        }
                        Spacer()
                        let short = a.shortRoles.count
                        Text(short == 0 ? "Floors met" : (short == 1 ? "1 floor short" : "\(short) floors short"))
                            .font(.caption)
                            .foregroundStyle(short == 0 ? Color.green : Color.orange)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("deck-analysis-summary")
            } else {
                Label(snapshot.format.hasCommander ? "Choose a commander to rate the deck" : "Composition and colour sources",
                      systemImage: "chart.bar.xaxis")
            }
        } else {
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading the deck…").foregroundStyle(.secondary)
            }
        }
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

    nonisolated private static func color(_ cls: ColorClass) -> Color {
        switch cls {
        case .multicolor: return Color(red: 0.85, green: 0.72, blue: 0.35)
        case .colorless: return ManaPalette.generic
        default: return ManaColor(rawValue: cls.rawValue).map(ManaPalette.color) ?? .gray
        }
    }

    // MARK: Mana cost and production

    /// What the deck asks for: coloured pips across every mana cost.
    private var manaCost: some View {
        Section {
            if stats.pips.isEmpty && stats.genericPips == 0 {
                Text("No mana costs yet.").foregroundStyle(.secondary)
            } else {
                pie(colors: stats.pips, colorless: includeGeneric ? stats.genericPips : 0, colorlessLabel: "Generic")
                Toggle("Include generic mana", isOn: $includeGeneric)
            }
        } header: {
            Text("Mana Cost")
        } footer: {
            Text("Coloured pips across every mana cost — what the deck asks for. Hybrids count for each colour.")
        }
    }

    /// What the deck makes: lands and rocks by the colours they add.
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
            Text("Lands and permanents that add mana, by the colours they can make — what the deck makes.")
        }
    }

    private struct BalanceBar: Identifiable {
        let color: String
        let kind: String
        let share: Double
        var id: String { color + kind }
    }

    /// Each colour's share of the pips beside its share of the sources —
    /// the two pies on one axis, so a colour the mana base under-serves
    /// shows as a longer cost bar. Only the colours the deck casts count:
    /// an "any colour" rock makes five colours, three of which a Boros
    /// deck never asks for, and counting them made every colour it does
    /// ask for look short.
    private var balanceBars: [BalanceBar] {
        let colors = ManaColor.allCases.filter { (stats.pips[$0] ?? 0) > 0 }
        let costTotal = colors.reduce(0) { $0 + (stats.pips[$1] ?? 0) }
        let sourceTotal = colors.reduce(0) { $0 + (stats.production[$1] ?? 0) }
        guard colors.count > 1, costTotal > 0, sourceTotal > 0 else { return [] }
        return colors.flatMap { color -> [BalanceBar] in
            let cost = Double(stats.pips[color] ?? 0) / Double(costTotal)
            let sources = Double(stats.production[color] ?? 0) / Double(sourceTotal)
            return [BalanceBar(color: color.name, kind: "Cost", share: cost), BalanceBar(color: color.name, kind: "Sources", share: sources)]
        }
    }

    @ViewBuilder private var balance: some View {
        let bars = balanceBars
        if !bars.isEmpty {
            Section {
                Chart(bars) { bar in
                    BarMark(x: .value("Share", bar.share), y: .value("Colour", bar.color))
                        .foregroundStyle(by: .value("Kind", bar.kind))
                        .position(by: .value("Kind", bar.kind))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(["Cost": Color.accentColor, "Sources": Color.secondary.opacity(0.45)])
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let x = value.as(Double.self) { Text(x, format: .percent.precision(.fractionLength(0))) }
                        }
                    }
                }
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: CGFloat(bars.count / 2) * 44 + 40)
                .padding(.vertical, 4)
                .accessibilityLabel("Colour balance: " + bars.map { "\($0.color) \($0.kind) \(Int(($0.share * 100).rounded()))%" }.joined(separator: ", "))
            } header: {
                Text("Colour Balance")
            } footer: {
                Text("Each colour's share of the pips against its share of the sources, over the colours the deck casts. A colour whose cost bar is longer is under-served by the mana base.")
            }
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
