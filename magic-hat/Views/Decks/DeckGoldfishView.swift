//
//  DeckGoldfishView.swift
//  magic-hat
//
//  The goldfish simulation as a tool: play or draw, five headline numbers
//  (land drops, mana used, the commander, colour trouble, mulligans),
//  then two charts — land drops by turn, mana made against mana spent.
//  Nothing the headline already says is charted again, and the opening
//  hand's land split lives in Draw Odds, where it is exact. Runs off the
//  main actor on every change; the last result stays on screen while
//  the next one runs. The "i" says what the player does and does not do.
//

import SwiftUI
import Charts

struct DeckGoldfishView: View {
    let snapshot: DeckSnapshot

    @State private var onThePlay = true
    private let games = 5_000
    @State private var result: GoldfishResult?

    private var config: GoldfishConfig {
        var c = GoldfishConfig()
        c.onThePlay = onThePlay
        c.games = games
        return c
    }

    var body: some View {
        List {
            settings
            if let result {
                headline(result)
                landDrops(result)
                mana(result)
            } else if snapshot.mainCopies == 0 {
                Section { Text("Add cards to the mainboard to run a simulation.").foregroundStyle(.secondary) }
            } else {
                Section {
                    HStack(spacing: 12) { ProgressView(); Text("Playing \(games.formatted()) games…").foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Goldfish")
        .navigationBarTitleDisplayMode(.inline)
        .toolGuide(Self.guide)
        .task(id: "\(config.hashValue)|\(snapshot.id)|\(snapshot.updatedDate.timeIntervalSince1970)") { await run() }
    }

    // MARK: Settings

    private var settings: some View {
        Section {
            Picker("Start", selection: $onThePlay) {
                Text("On the Play").tag(true)
                Text("On the Draw").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("goldfish-start")
        } footer: {
            Text("\(games.formatted()) games of \(GoldfishConfig().turns) turns. Keeps a seven with 2–5 lands, mulligans up to twice. No opponent: what the deck does on its own.")
        }
    }

    // MARK: Headline

    private func headline(_ r: GoldfishResult) -> some View {
        Section {
            stat("Every land drop through turn 4", r.everyLandDrop[safe: 4], id: "goldfish-land-drops")
            stat("Mana spent, of mana made", r.efficiency, id: "goldfish-efficiency")
            if !r.commanderCastBy.isEmpty {
                let by = min(r.turns, max(1, Int((r.commanderMeanTurn ?? 4).rounded(.up))))
                stat("Commander cast by turn \(by)", r.commanderCastBy[safe: by], id: "goldfish-commander",
                     detail: r.commanderMeanTurn.map { "on average turn \($0.formatted(.number.precision(.fractionLength(1))))" })
            }
            stat("Stuck on colours by turn 4", r.colorStuckBy[safe: 4], id: "goldfish-stuck", tint: .orange,
                 detail: "a spell that fit the mana but not its colours — Mana Base says which")
            stat("Hands mulliganed", 1 - (r.mulligans.first ?? 1), id: "goldfish-mulligans", tint: .secondary)
        } header: {
            Text("At a Glance")
        }
    }

    private func stat(_ title: String, _ value: Double?, id: String, tint: Color = .accentColor, detail: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            OddsCell(value: value ?? 0, tint: tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: Charts

    private struct TurnPoint: Identifiable {
        let turn: Int
        let series: String
        let value: Double
        var id: String { "\(series)\(turn)" }
        /// The axis is categorical so every turn gets its label.
        var label: String { "\(turn)" }
    }

    private func turnLabels(_ r: GoldfishResult) -> [String] { (1...r.turns).map { "\($0)" } }

    private func perTurn(_ r: GoldfishResult, _ series: String, _ values: [Double]) -> [TurnPoint] {
        (1...r.turns).compactMap { t in values[safe: t].map { TurnPoint(turn: t, series: series, value: $0) } }
    }

    private func landDrops(_ r: GoldfishResult) -> some View {
        let points = perTurn(r, "That turn", r.landDrop) + perTurn(r, "Every turn so far", r.everyLandDrop)
        let turns = turnLabels(r)
        return Section {
            Chart(points) { p in
                LineMark(x: .value("Turn", p.label), y: .value("Chance", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Turn", p.label), y: .value("Chance", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
            }
            .chartYScale(domain: 0...1)
            .chartYAxis { PercentAxis.marks() }
            .chartXScale(domain: turns)
            .chartForegroundStyleScale(["That turn": Color.accentColor, "Every turn so far": Color.green])
            .chartLegend(position: .bottom, spacing: 8)
            .frame(height: 200)
            .padding(.vertical, 4)
        } header: {
            Text("Land Drops")
        } footer: {
            Text("The chance a land was played on each turn, and of having made every drop so far.")
        }
    }

    private func mana(_ r: GoldfishResult) -> some View {
        let points = perTurn(r, "Available", r.manaAvailable) + perTurn(r, "Spent", r.manaSpent)
        let turns = turnLabels(r)
        return Section {
            Chart(points) { p in
                BarMark(x: .value("Turn", p.label), y: .value("Mana", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .position(by: .value("Series", p.series))
                    .cornerRadius(3)
            }
            .chartXScale(domain: turns)
            .chartForegroundStyleScale(["Available": Color.secondary.opacity(0.45), "Spent": Color.accentColor])
            .chartLegend(position: .bottom, spacing: 8)
            .frame(height: 200)
            .padding(.vertical, 4)
        } header: {
            Text("Mana")
        } footer: {
            Text("Mana the battlefield could make each turn against what was spent. A wide gap means the hand had nothing to cast, or nothing it could pay for.")
        }
    }

    // MARK: Running

    private func run() async {
        guard snapshot.mainCopies > 0 else { return }
        let cards = Goldfish.cards(from: snapshot)
        let config = config
        let r = await Self.simulate(cards, config: config)
        guard !Task.isCancelled else { return }
        result = r
    }

    @concurrent
    private nonisolated static func simulate(_ cards: [GoldfishCard], config: GoldfishConfig) async -> GoldfishResult {
        Goldfish.run(cards, config: config)
    }

    static let guide = ToolGuide(
        title: "About Goldfish",
        sections: [
            .init(title: "What it is", rows: [
                .init(icon: "fish", title: "The deck against nobody",
                      text: "Thousands of games played by a simple, honest player: shuffle, seven, draw, play a land, cast what the mana allows. No opponent, no combat, no removal — what the deck does on its own when nothing interferes."),
                .init(icon: "dice", title: "Why thousands",
                      text: "Each number is a share of 5,000 games, good to about a point either way. It runs again whenever the list changes."),
            ]),
            .init(title: "How the player plays", rows: [
                .init(icon: "hand.raised", title: "Keeping a hand",
                      text: "A seven with two to five lands is kept. Otherwise it is a London mulligan: seven again, and one card to the bottom per mulligan — surplus lands first, else the most expensive spells. At most two."),
                .init(icon: "mountain.2", title: "Land drops",
                      text: "One a turn, the land that helps most: untapped when there is something to cast with it, a colour the hand wants and the battlefield lacks."),
                .init(icon: "wand.and.stars", title: "Casting",
                      text: "Ramp first (rocks, dorks, land fetchers), then a draw spell, then the commander, then the biggest spell the mana can pay for, with its colours. Rocks tap at once; creatures wait a turn. Cantrips draw, fetchers put a basic onto the battlefield."),
            ]),
            .init(title: "What it leaves out", rows: [
                .init(icon: "nosign", title: "No rules engine",
                      text: "Cards are read by their cost, type and a few phrases of rules text. Treasure makers, cost reducers, free spells, rituals and anything conditional are played as plain spells of their mana value."),
                .init(icon: "chart.line.uptrend.xyaxis", title: "Read it as a ceiling",
                      text: "An opponent only makes it worse. Land drops, colours and mana spent are what the list controls; use Draw Odds for a single card and Mana Base for which colour is short."),
            ]),
        ],
        source: "Method after Frank Karsten's land-count and colour-source analyses (ChannelFireball 2017, TCGplayer 2022): Monte Carlo goldfish with a land-count mulligan rule."
    )
}

extension Array where Element == Double {
    subscript(safe index: Int) -> Double? { indices.contains(index) ? self[index] : nil }
}

/// A y axis in whole percentages, for the odds charts.
enum PercentAxis {
    @AxisContentBuilder
    static func marks(automatic: Bool = false) -> some AxisContent {
        AxisMarks(values: automatic ? .automatic(desiredCount: 3) : .stride(by: 0.5)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let d = value.as(Double.self) {
                    Text(d, format: .percent.precision(.fractionLength(0)))
                }
            }
        }
    }
}
