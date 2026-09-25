//
//  DeckAnalysisView.swift
//  magic-hat
//
//  The deck read against the Commander rules of thumb, pushed from Stats:
//  the three scores with how each is made, the Bracket and its signals,
//  composition against the floors, colour sources against Karsten's
//  numbers, the commander's engine, the combos in the list and the ones a
//  card away, how widely its cards are played, and the rules it breaks.
//  Everything comes from DeckAnalysisController — the local reading first,
//  the outside signals as they land — so the screen is never blank waiting
//  on a request, and each section says what it could not check.
//

import SwiftUI
import SwiftData

struct DeckAnalysisView: View {
    let snapshot: DeckSnapshot
    let controller: DeckAnalysisController
    /// Opens the add sheet on its Recommended scope.
    var onAddRecommended: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            if let analysis = controller.analysis {
                if analysis.isCommander {
                    scores(analysis)
                    if let bracket = analysis.bracket { self.bracket(bracket) }
                } else {
                    Section {
                        Label(snapshot.format.hasCommander ? "Choose a commander to rate the deck." : "Scores and the Bracket are for Commander decks; the rest is read for any list.",
                              systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                composition(analysis)
                sources(analysis)
                if !analysis.engine.isEmpty { engine(analysis) }
                speed(analysis)
                combos(analysis)
                table(analysis)
                rules(analysis)
                recommendations
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading the deck…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Analysis")
        .navigationSubtitle(snapshot.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Scores

    private func scores(_ a: DeckAnalysis) -> some View {
        Section {
            HStack(spacing: 0) {
                ScoreGauge(title: "Power", score: a.power, tint: .orange)
                ScoreGauge(title: "Impact", score: a.impact, tint: .red)
                ScoreGauge(title: "Playability", score: a.playability, tint: .green)
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("analysis-scores")
            scoreParts("Power", a.power, note: "Starts at 2; the parts add up, out of 10.")
            scoreParts("Impact", a.impact, note: "Starts at 1; the parts add up, out of 10.")
            scoreParts("Playability", a.playability, note: "Starts at 10; each shortfall takes from it.")
        } header: {
            Text("Scores")
        } footer: {
            Text("From the list alone. Power is the whole; impact is how hard it hits the table; playability is how reliably it does its thing.")
        }
    }

    private func scoreParts(_ title: String, _ score: DeckAnalysis.Score, note: String) -> some View {
        DisclosureGroup {
            ForEach(score.parts) { part in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(part.label)
                        Spacer()
                        Text(Self.signed(part.value) + " / " + Self.trim(part.max))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Text(part.text).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            ForEach(score.notes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Text(note).font(.caption).foregroundStyle(.tertiary)
        } label: {
            HStack {
                Text("How \(title.lowercased()) is made")
                Spacer()
                Text(score.band).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    // MARK: Bracket

    private func bracket(_ b: DeckAnalysis.Bracket) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Bracket \(b.level)").font(.title2.weight(.semibold))
                    Text(b.name.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                ForEach(b.reasons, id: \.self) { reason in
                    Text(reason).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("analysis-bracket")
            DisclosureGroup("Signals") {
                ForEach(b.signals) { signal in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(signal.label).font(.subheadline)
                            Text(signal.text).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let level = signal.level {
                            Text("→ \(level)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(level == b.level && level > 2 ? Color.accentColor : .secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .font(.subheadline)
        } header: {
            Text("Commander Bracket")
        } footer: {
            Text("Bracket 1 is a table agreement and 5 is declared, so the rating runs 2–4. Game changers from Scryfall's list; combos from Commander Spellbook.")
        }
    }

    // MARK: Composition

    private func composition(_ a: DeckAnalysis) -> some View {
        Section {
            ForEach(a.composition) { role in
                DisclosureGroup {
                    if role.cards.isEmpty {
                        Text("None yet.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(role.cards) { card in
                            Text(card.quantity > 1 ? "\(card.quantity)× \(card.name)" : card.name)
                                .font(.caption)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: role.role.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(role.isShort ? Color.orange : Color.green)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(role.role.label)
                                Spacer()
                                Text("\(role.count) / \(role.floor)+")
                                    .monospacedDigit()
                                    .foregroundStyle(role.isShort ? Color.orange : Color.secondary)
                            }
                            .font(.subheadline)
                            ProgressView(value: Double(min(role.count, role.floor)), total: Double(role.floor))
                                .tint(role.isShort ? .orange : .green)
                        }
                    }
                }
                .accessibilityIdentifier("analysis-role-\(role.role.rawValue)")
            }
        } header: {
            let short = a.shortRoles.count
            Text(short > 0 ? "Composition · \(short) short" : "Composition")
        } footer: {
            Text("Counted from rules text against the usual floors: 34 lands, 8 ramp, 8 draw, 8 removal, a wipe, a couple of tutors. A floor is a floor, not a target.")
        }
    }

    private func sources(_ a: DeckAnalysis) -> some View {
        Section {
            if a.sources.isEmpty {
                Text("No colours to judge yet.").foregroundStyle(.secondary)
            }
            ForEach(a.sources) { source in
                DisclosureGroup {
                    ForEach(source.cards) { card in
                        Text(card.quantity > 1 ? "\(card.quantity)× \(card.name)" : card.name).font(.caption)
                    }
                } label: {
                    HStack(spacing: 10) {
                        ManaSymbolView(symbol: ManaSymbol(source.color.rawValue), size: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(source.color.name)
                                Spacer()
                                if let target = source.target {
                                    Text("\(source.count) / ~\(target)")
                                        .monospacedDigit()
                                        .foregroundStyle(source.isShort ? Color.orange : Color.secondary)
                                } else {
                                    Text("\(source.count)").monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .font(.subheadline)
                            if let target = source.target {
                                ProgressView(value: Double(min(source.count, target)), total: Double(target))
                                    .tint(source.isShort ? .orange : .green)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Colour Sources")
        } footer: {
            Text(a.isCommander
                 ? "Lands and rocks that make each colour, against Karsten's numbers: about 22 sources for a colour the commander needs one pip of, 29 for two or more."
                 : "Lands and rocks that make each colour.")
        }
    }

    private func engine(_ a: DeckAnalysis) -> some View {
        Section {
            Text(DeckAnalysis.list(a.engine).prefix(1).uppercased() + DeckAnalysis.list(a.engine).dropFirst() + ".")
                .font(.subheadline)
        } header: {
            Text("The Commander Pays Off")
        } footer: {
            Text("Read from the commander's text. Cards that touch these count as on-plan in the swap table.")
        }
    }

    private func speed(_ a: DeckAnalysis) -> some View {
        Section("Speed") {
            LabeledContent("Average mana value", value: DeckAnalysis.format(a.averageManaValue))
            LabeledContent("Fast mana", value: a.fastMana.isEmpty ? "None" : DeckAnalysis.list(a.fastMana))
            LabeledContent("Free interaction", value: a.freeInteraction.isEmpty ? "None" : DeckAnalysis.list(a.freeInteraction))
            LabeledContent("Counterspells", value: "\(a.counterspells)")
        }
        .font(.subheadline)
    }

    // MARK: Combos

    @ViewBuilder private func combos(_ a: DeckAnalysis) -> some View {
        Section {
            switch controller.combos {
            case .pending:
                HStack(spacing: 12) { ProgressView(); Text("Asking Commander Spellbook…").foregroundStyle(.secondary) }
            case .offline:
                Text("Combos need a connection.").foregroundStyle(.secondary)
            case .unavailable:
                Text(a.isCommander ? "Commander Spellbook couldn't be reached." : "Combos are checked for Commander decks.")
                    .foregroundStyle(.secondary)
            case .done:
                if a.combos.isEmpty {
                    Text("No combos in the list.").foregroundStyle(.secondary)
                }
                ForEach(a.combos) { combo in comboRow(combo, missing: nil) }
            }
        } header: {
            Text("Combos")
        }
        if controller.combos == .done, !a.nearCombos.isEmpty {
            Section {
                ForEach(a.nearCombos.prefix(8)) { combo in comboRow(combo, missing: combo.missing) }
            } header: {
                Text("One Card Away")
            } footer: {
                Text("The missing piece leads the recommendations.")
            }
        }
    }

    private func comboRow(_ combo: DeckCombo, missing: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let missing {
                Text("\(combo.cards.filter { $0 != missing }.joined(separator: " + ")) + \(Text(missing).bold())")
                    .font(.subheadline)
            } else {
                Text(combo.title).font(.subheadline)
            }
            HStack(spacing: 6) {
                if let result = combo.result { Text("→ " + result) }
                if !combo.manaNeeded.isEmpty { ManaCostView(cost: combo.manaNeeded, size: 11) }
                if combo.isEarly { Text("early").foregroundStyle(.orange) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func table(_ a: DeckAnalysis) -> some View {
        Section {
            if let rank = a.medianRank, let band = a.rankBand {
                VStack(alignment: .leading, spacing: 4) {
                    Text(band).font(.subheadline)
                    Text("The middle card of this deck is about number \(rank.formatted()) in Commander, across \(a.rankedCards) of its cards.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Card ranks arrive with card data.").foregroundStyle(.secondary)
            }
        } header: {
            Text("At the Table")
        } footer: {
            Text("How often its cards are played, from Scryfall's EDHREC rank — the median, so one staple doesn't make a jank pile look tuned.")
        }
    }

    private func rules(_ a: DeckAnalysis) -> some View {
        Section {
            if a.problems.isEmpty {
                Label("Nothing wrong with the list.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                ForEach(a.problems) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(issue.kind.isViolation ? .orange : .secondary)
                }
            }
        } header: {
            Text("Rules")
        }
    }

    private var recommendations: some View {
        Section {
            if let onAddRecommended {
                Button {
                    onAddRecommended()
                } label: {
                    HStack {
                        Label("Recommended Cards", systemImage: "wand.and.stars").foregroundStyle(.primary)
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
                .accessibilityIdentifier("analysis-recommendations")
            }
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
            .accessibilityIdentifier("analysis-swaps")
        } footer: {
            Text(controller.sourcesLine)
        }
    }

    // MARK: Formatting

    private static func signed(_ x: Double) -> String {
        let s = trim(abs(x))
        return x < 0 ? "−" + s : (x > 0 ? "+" + s : s)
    }

    private static func trim(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.2f", x).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}

/// One score as a circular gauge with its band under it.
struct ScoreGauge: View {
    let title: String
    let score: DeckAnalysis.Score
    let tint: Color
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            Gauge(value: score.score, in: 1...10) {
                Text(title)
            } currentValueLabel: {
                Text(score.score, format: .number.precision(.fractionLength(1)))
                    .font(compact ? .caption.weight(.semibold) : .body.weight(.semibold))
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .scaleEffect(compact ? 0.8 : 1)
            .frame(height: compact ? 44 : 56)
            Text(title).font(compact ? .caption2 : .caption).foregroundStyle(.primary)
            if !compact {
                Text(score.band).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(score.score, format: .number.precision(.fractionLength(1))) out of 10, \(score.band)")
    }
}
