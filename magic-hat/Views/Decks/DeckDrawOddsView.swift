//
//  DeckDrawOddsView.swift
//  magic-hat
//
//  Draw odds as a table: every card of the mainboard with the chance of
//  having it in the opening hand and by a chosen turn, the lands as a
//  group on top with how the opening seven split. Tap rows to select a
//  few and the header says the odds of seeing any of them, and all of
//  them, by that turn — "a piece of the combo by turn 4". Exact
//  (hypergeometric), so it is instant; the table is built off the main
//  actor once and filtered by the field.
//

import SwiftUI
import Charts

struct DeckDrawOddsView: View {
    let snapshot: DeckSnapshot

    @State private var odds: DrawOdds?
    @State private var turn = 4
    @State private var onThePlay = true
    @State private var filter = ""
    @State private var selected: Set<String> = []

    private static let maxSelected = 6

    var body: some View {
        List {
            controls
            if let odds {
                if !selected.isEmpty { selection(odds) }
                if let lands = odds.rows.first(where: \.isGroup) { landsSection(odds, lands) }
                cards(odds)
            } else if snapshot.mainCopies == 0 {
                Section { Text("Add cards to the mainboard to see draw odds.").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Draw Odds")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter cards")
        .toolGuide(Self.guide)
        .task(id: "\(snapshot.id)|\(snapshot.updatedDate.timeIntervalSince1970)") {
            odds = await Self.build(snapshot)
        }
    }

    private var seen: Int { DrawOdds.cardsSeen(byTurn: turn, onThePlay: onThePlay) }

    // MARK: Controls

    private var controls: some View {
        Section {
            Stepper(value: $turn, in: 1...15) {
                LabeledContent("By turn") { Text("\(turn)").monospacedDigit() }
            }
            .accessibilityIdentifier("odds-turn")
            Picker("Start", selection: $onThePlay) {
                Text("On the Play").tag(true)
                Text("On the Draw").tag(false)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("\(seen) of \(odds?.librarySize ?? snapshot.mainCopies) cards seen by the start of turn \(turn); turn 1 on the play is the opening hand. Tap rows to combine them.")
        }
    }

    // MARK: Selection

    private func selection(_ odds: DrawOdds) -> some View {
        let rows = odds.rows.filter { selected.contains($0.id) }
        return Section {
            HStack {
                Text("Any of them by turn \(turn)")
                Spacer()
                OddsCell(value: odds.chanceOfAny(rows, byTurn: turn, onThePlay: onThePlay), tint: .green)
            }
            .accessibilityIdentifier("odds-any")
            HStack {
                Text("All of them by turn \(turn)")
                Spacer()
                OddsCell(value: odds.chanceOfAll(rows, byTurn: turn, onThePlay: onThePlay), tint: .purple)
            }
            .accessibilityIdentifier("odds-all")
            Button("Clear Selection", role: .destructive) { selected = [] }
        } header: {
            Text(rows.count == 1 ? "1 Selected" : "\(rows.count) Selected")
        } footer: {
            Text(rows.map(\.name).joined(separator: ", "))
        }
    }

    // MARK: Lands

    private struct Bar: Identifiable {
        let lands: Int
        let chance: Double
        var id: Int { lands }
    }

    private func landsSection(_ odds: DrawOdds, _ lands: DrawOdds.Row) -> some View {
        let bars = odds.openingDistribution(copies: lands.copies).enumerated().map { Bar(lands: $0.offset, chance: $0.element) }
        let good = (2...5).reduce(0.0) { $0 + (bars[safeBar: $1]?.chance ?? 0) }
        return Section {
            Chart(bars) { bar in
                BarMark(x: .value("Lands", "\(bar.lands)"), y: .value("Chance", bar.chance))
                    .foregroundStyle(bar.lands >= 2 && bar.lands <= 5 ? Color.accentColor.gradient : Color.secondary.opacity(0.4).gradient)
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        if bar.chance >= 0.02 { Text(bar.chance, format: .percent.precision(.fractionLength(0))).font(.caption2).monospacedDigit() }
                    }
            }
            .chartYAxis(.hidden)
            .frame(height: 150)
            .padding(.vertical, 4)
            .accessibilityLabel("Lands in the opening hand: " + bars.map { "\($0.lands): \(Int(($0.chance * 100).rounded()))%" }.joined(separator: ", "))
            HStack {
                Text("2–5 lands in the opening seven")
                Spacer()
                OddsCell(value: good)
            }
            .accessibilityIdentifier("odds-keepable")
        } header: {
            Text("Lands · \(lands.copies)")
        }
    }

    // MARK: Cards

    private func cards(_ odds: DrawOdds) -> some View {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = odds.rows.filter { !$0.isGroup && (query.isEmpty || $0.name.lowercased().contains(query)) }
        return Section {
            ForEach(rows) { row in
                Button {
                    toggle(row.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(row.id) ? Color.accentColor : Color.secondary)
                        Text(row.name).foregroundStyle(.primary).lineLimit(1)
                        if row.copies > 1 { Text("×\(row.copies)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        Spacer()
                        OddsCell(value: odds.chance(copies: row.copies, byTurn: turn, onThePlay: onThePlay))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("odds-row-\(row.name)")
            }
            if rows.isEmpty { Text("No cards match.").foregroundStyle(.secondary) }
        } header: {
            Text("By Turn \(turn)")
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) }
        else if selected.count < Self.maxSelected { selected.insert(id) }
    }

    @concurrent
    private nonisolated static func build(_ snapshot: DeckSnapshot) async -> DrawOdds {
        DrawOdds(snapshot: snapshot)
    }

    static let guide = ToolGuide(
        title: "About Draw Odds",
        sections: [
            .init(title: "What it is", rows: [
                .init(icon: "percent", title: "Exact, not simulated",
                      text: "The chance of drawing a card is a counting problem: so many copies in so many cards, so many drawn. The hypergeometric distribution answers it exactly, so every number here is precise — no games are played."),
                .init(icon: "7.square", title: "Cards seen",
                      text: "The opening seven, then one a turn. On the play the first draw is skipped, so turn 4 means ten cards seen; on the draw, eleven. Commanders are not in the library."),
            ]),
            .init(title: "Reading the table", rows: [
                .init(icon: "list.bullet", title: "Each card",
                      text: "The chance of having drawn at least one copy by the start of the chosen turn. Set the turn to 1 on the play for the opening hand."),
                .init(icon: "mountain.2", title: "Lands",
                      text: "How the opening seven splits by land count; the bars from two to five are the keepable hands. For land drops turn by turn, run Goldfish."),
                .init(icon: "checkmark.circle", title: "Combine cards",
                      text: "Tap up to six rows. Any: at least one of them. All: every one of them — the odds of assembling a pair or a package by that turn. Mulligans and tutors are not counted; they only improve it."),
            ]),
        ],
        source: "Hypergeometric draw odds, as used in every mana-base and consistency analysis since the game began."
    )
}

private extension Array {
    subscript(safeBar index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
