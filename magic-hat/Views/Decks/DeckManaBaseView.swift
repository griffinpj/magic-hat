//
//  DeckManaBaseView.swift
//  magic-hat
//
//  The mana base report as a tool: each colour the deck casts with its
//  sources against the target its most demanding early spell sets and
//  the chance of having them on time; the land count against the formula;
//  the basics the deck runs split to meet every target; every source
//  with the colours it makes and which colour would fall short without
//  it. Exact arithmetic, built off the main actor on arrival.
//

import SwiftUI
import Charts

struct DeckManaBaseView: View {
    let snapshot: DeckSnapshot

    @State private var report: ManaBaseReport?

    var body: some View {
        List {
            if let report {
                if report.colors.isEmpty && report.lands == 0 {
                    Section { Text("Add spells and lands to the mainboard to judge the mana base.").foregroundStyle(.secondary) }
                } else {
                    colours(report)
                    lands(report)
                    if !report.basics.isEmpty { basics(report) }
                    if !report.sources.isEmpty { sources(report) }
                }
            } else {
                Section { HStack(spacing: 12) { ProgressView(); Text("Reading the lands…").foregroundStyle(.secondary) } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Mana Base")
        .navigationBarTitleDisplayMode(.inline)
        .toolGuide(Self.guide)
        .task(id: "\(snapshot.id)|\(snapshot.updatedDate.timeIntervalSince1970)") {
            report = await Self.build(snapshot)
        }
    }

    // MARK: Colours

    private struct SourceBar: Identifiable {
        let color: String
        let kind: String
        let count: Int
        var id: String { color + kind }
    }

    private func colours(_ r: ManaBaseReport) -> some View {
        Section {
            if r.colors.isEmpty {
                Text("No coloured costs yet.").foregroundStyle(.secondary)
            }
            ForEach(r.colors) { line in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ManaSymbolView(symbol: ManaSymbol(line.color.rawValue), size: 18)
                        Text(line.color.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(line.sources) of \(line.target) sources")
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(line.isShort ? Color.orange : Color.green)
                    }
                    ProgressView(value: Double(min(line.sources, line.target)), total: Double(max(1, line.target)))
                        .tint(line.isShort ? .orange : .green)
                    HStack {
                        Text("\(line.pips) pips · \(Self.pips(line.demandPips, line.color)) on turn \(line.demandTurn): \(line.demandName)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Text(line.chance, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(line.chance >= ManaBase.confidence ? Color.green : Color.orange)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("manabase-\(line.color.rawValue)")
            }
        } header: {
            Text("Colours")
        } footer: {
            Text("Sources: lands and permanents costing two or less that make the colour. Target: enough of them to have the colour for the most demanding early spell on its turn in 90% of games where the land drops were made. The percentage is that chance with the sources as they stand.")
        }
    }

    private static func pips(_ n: Int, _ color: ManaColor) -> String {
        String(repeating: "{\(color.rawValue)}", count: n)
    }

    // MARK: Lands

    private func lands(_ r: ManaBaseReport) -> some View {
        Section {
            LabeledContent("Lands") {
                HStack(spacing: 6) {
                    Text("\(r.lands)").monospacedDigit()
                    if r.lands != r.suggestedLands {
                        Text(r.lands < r.suggestedLands ? "▲ \(r.suggestedLands - r.lands)" : "▼ \(r.lands - r.suggestedLands)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                }
            }
            .accessibilityIdentifier("manabase-lands")
            LabeledContent("Enter untapped") { Text(r.untappedShare, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
        } header: {
            Text("Land Count")
        } footer: {
            Text(r.lands == r.suggestedLands
                 ? "Karsten's count for this curve (average mana value \(r.averageManaValue.formatted(.number.precision(.fractionLength(1)))), \(r.cheapRampAndDraw) cheap ramp or draw) is \(r.suggestedLands)."
                 : "Karsten's count for this curve (average mana value \(r.averageManaValue.formatted(.number.precision(.fractionLength(1)))), \(r.cheapRampAndDraw) cheap ramp or draw) is \(r.suggestedLands). A starting point: a low curve or many cantrips wants fewer.")
        }
    }

    // MARK: Basics

    private func basics(_ r: ManaBaseReport) -> some View {
        Section {
            ForEach(r.basics) { split in
                HStack(spacing: 8) {
                    ManaSymbolView(symbol: ManaSymbol(split.color.rawValue), size: 18)
                    Text(Self.basicName(split.color))
                    Spacer()
                    Text("\(split.current)").monospacedDigit().foregroundStyle(split.change == 0 ? .primary : .secondary)
                    if split.change != 0 {
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        Text("\(split.suggested)").monospacedDigit().fontWeight(.semibold)
                            .foregroundStyle(split.change > 0 ? Color.green : Color.orange)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Basics")
        } footer: {
            Text(r.basicsChange
                 ? "The same number of basics, split so each colour reaches its target where it can and the rest follow the pips."
                 : "Already split the way the targets ask.")
        }
    }

    private static func basicName(_ color: ManaColor) -> String {
        switch color {
        case .white: return "Plains"
        case .blue: return "Island"
        case .black: return "Swamp"
        case .red: return "Mountain"
        case .green: return "Forest"
        }
    }

    // MARK: Sources

    private func sources(_ r: ManaBaseReport) -> some View {
        Section {
            ForEach(r.sources) { source in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(source.name).lineLimit(1)
                            if source.copies > 1 { Text("×\(source.copies)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        HStack(spacing: 4) {
                            if !source.isLand { Text("Producer").font(.caption).foregroundStyle(.secondary) }
                            if source.entersTapped { Text("Enters tapped").font(.caption).foregroundStyle(.secondary) }
                            if !source.holds.isEmpty {
                                Text("Holds " + source.holds.map(\.name).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    Spacer()
                    HStack(spacing: 2) {
                        if source.anyColor {
                            Text("Any").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        } else {
                            ForEach(source.colors, id: \.self) { ManaSymbolView(symbol: ManaSymbol($0.rawValue), size: 14) }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Non-basic Sources")
        } footer: {
            Text("“Holds” marks a source a colour cannot spare: cut one copy and that colour drops below its target.")
        }
    }

    @concurrent
    private nonisolated static func build(_ snapshot: DeckSnapshot) async -> ManaBaseReport {
        ManaBase.report(snapshot: snapshot)
    }

    static let guide = ToolGuide(
        title: "About Mana Base",
        sections: [
            .init(title: "Colours", rows: [
                .init(icon: "drop", title: "Sources and targets",
                      text: "A source is a land, or a permanent costing two or less, that makes the colour. The target is how many the deck needs for its most demanding early spell — a two-drop with two black pips asks for far more Swamps than a six-drop with one."),
                .init(icon: "percent", title: "How the target is set",
                      text: "Count the cards seen by the spell's turn, the sources among them, in games where the land drops were made; the target is the number of sources at which that spell is castable on time in 90% of those games. Worked out exactly for this deck's size rather than read from a table."),
                .init(icon: "exclamationmark.triangle", title: "Short",
                      text: "A colour below its target shows in orange with the chance as it stands. Fix it with the basics split below, a dual in place of a basic of the other colour, or a cheaper spell of that colour."),
            ]),
            .init(title: "Lands", rows: [
                .init(icon: "mountain.2", title: "The count",
                      text: "Frank Karsten's 2022 formula from the deck's average mana value, less a little for each cheap spell that draws or makes mana. It is a starting point; a deck with many cantrips or a low curve wants fewer."),
                .init(icon: "arrow.left.arrow.right", title: "Basics",
                      text: "Keeps the number of basics you run and splits them to meet every colour's target where it can, the rest by each colour's share of the pips. Non-basic lands stay as they are."),
                .init(icon: "lock", title: "Holds",
                      text: "A source marked Holds is one a colour cannot lose: one fewer and that colour drops below its target. Cut from the others first."),
            ]),
            .init(title: "What it leaves out", rows: [
                .init(icon: "nosign", title: "Not counted",
                      text: "Fetch lands count only for the colours printed on them; rituals, treasure makers and cost reducers are not sources; a land that enters tapped counts the same as one that does not (the share of untapped lands is shown instead)."),
            ]),
        ],
        source: "After Frank Karsten, “How Many Sources Do You Need to Consistently Cast Your Spells?” (2013, 2018, 2022) and “How Many Lands Do You Need?” (2017, 2022)."
    )
}
