//
//  CommanderFinderView.swift
//  magic-hat
//
//  "Build with what you have": the hundred commanders people build most,
//  each with how much of its average deck the collection already holds —
//  best first, filling in as the scan runs. A row opens the commander's
//  page: the cards owned and the cards missing with their prices, Buy
//  for the missing ones, and Copy List to paste into a new deck.
//

import SwiftUI
import SwiftData

struct CommanderFinderView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var period: EDHRECPeriod = .week
    @State private var filter = ""

    private var finder: CommanderFinder { .shared }

    var body: some View {
        List {
            Section {
                Picker("Commanders", selection: $period) {
                    ForEach(EDHRECPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("finder-period")
                if finder.isScanning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: finder.progress)
                        Text(finder.total == 0 ? "Fetching the list…" : "Scored \(finder.scanned) of \(finder.total)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityIdentifier("finder-progress")
                } else if let error = finder.error {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary).font(.subheadline)
                    Button("Try Again") { scan(force: true) }
                }
            } footer: {
                if let at = finder.scannedAt, !finder.isScanning {
                    Text("Scored against the collection \(at, style: .relative) ago. Pull to rescan.")
                } else {
                    Text("Each commander's average deck on EDHREC, counted against the cards you own.")
                }
            }
            results
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Find a Commander")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter commanders")
        .toolGuide(Self.guide)
        .refreshable { scan(force: true) }
        .onAppear {
            period = finder.period
            if finder.matches.isEmpty && !finder.isScanning { scan() }
        }
        .onChange(of: period) { _, p in if p != finder.period { scan() } }
    }

    private var rows: [CommanderMatch] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? finder.matches : finder.matches.filter { $0.name.lowercased().contains(q) }
    }

    @ViewBuilder private var results: some View {
        let rows = rows
        if !rows.isEmpty {
            Section {
                ForEach(rows) { match in
                    NavigationLink {
                        CommanderMatchView(match: match)
                    } label: {
                        CommanderMatchRow(match: match)
                    }
                    .accessibilityIdentifier("finder-row-\(match.name)")
                }
            } header: {
                Text(rows.count == finder.matches.count ? "Commanders · \(rows.count)" : "\(rows.count) of \(finder.matches.count)")
            }
        } else if !finder.isScanning && finder.error == nil && !finder.matches.isEmpty {
            Section { Text("No commanders match.").foregroundStyle(.secondary) }
        }
    }

    private func scan(force: Bool = false) {
        finder.scan(period: period, container: modelContext.container, force: force)
    }

    static let guide = ToolGuide(
        title: "About Find a Commander",
        sections: [
            .init(title: "What it is", rows: [
                .init(icon: "sparkle.magnifyingglass", title: "Build with what you have",
                      text: "The hundred commanders most people are building — this week, this month, or over two years — each scored by how much of its average deck you already own. The best fit first."),
                .init(icon: "person.crop.rectangle.stack", title: "The average deck",
                      text: "EDHREC's hundred cards that most decks for that commander agree on, the commander left out. Not a tuned list: a template, and a fair measure of what a deck for them usually needs."),
                .init(icon: "checkmark.circle", title: "Owned",
                      text: "Counted by name across your collections and lists — any printing, each copy once, basics by count. Cards in built decks count as owned; they would have to move."),
            ]),
            .init(title: "A commander's page", rows: [
                .init(icon: "cart", title: "Missing",
                      text: "The cards the average deck has that you don't, with today's prices and the total — what the deck would cost to finish. Buy sends the list to a store."),
                .init(icon: "doc.on.clipboard", title: "Copy List",
                      text: "Copies the whole average deck as a list to paste into a new deck, and shape from there."),
            ]),
            .init(title: "Where it comes from", rows: [
                .init(icon: "arrow.clockwise", title: "Scanning",
                      text: "One page per commander from EDHREC, politely spaced, so the first scan takes under a minute and fills in as it goes. Pages are kept a week; pull down to rescan."),
            ]),
        ],
        source: "Data: EDHREC's average decks and top commanders. Scores are an overlap count, nothing more."
    )
}

private struct CommanderMatchRow: View {
    let match: CommanderMatch

    var body: some View {
        HStack(spacing: 12) {
            CardArtThumb(artURL: match.artURL, fallbackURL: match.imageURL, width: 56, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(match.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if match.commanderOwned {
                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            .accessibilityLabel("Commander owned")
                    }
                }
                Text("#\(match.rank) · \(match.numDecks.formatted()) decks")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(match.ownedCopies) of \(match.totalCopies)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                OddsCell(value: match.share, tint: tint, width: 48)
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        match.share >= 0.7 ? .green : (match.share >= 0.45 ? .accentColor : .orange)
    }
}

/// One commander: what the average deck wants, owned and missing.
struct CommanderMatchView: View {
    let match: CommanderMatch

    @Environment(\.modelContext) private var modelContext
    @State private var cards: [String: CardItem] = [:]
    @State private var copied = false

    private var missing: [CommanderMatch.Line] { match.missingLines }

    private var missingValue: Double {
        missing.reduce(0) { $0 + (cards[$1.name]?.price ?? 0) * Double($1.missing) }
    }
    private var pricedMissing: Int { missing.filter { cards[$0.name]?.price != nil }.count }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    CardArtThumb(artURL: match.artURL, fallbackURL: match.imageURL, width: 84, height: 60, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(match.name).font(.headline)
                        Text("#\(match.rank) · \(match.numDecks.formatted()) decks on EDHREC").font(.caption).foregroundStyle(.secondary)
                        Text(match.commanderOwned ? "Commander owned" : "Commander not owned")
                            .font(.caption).foregroundStyle(match.commanderOwned ? Color.green : Color.secondary)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("Owned") { Text("\(match.ownedCopies) of \(match.totalCopies)").monospacedDigit() }
                LabeledContent("Missing") {
                    Text(pricedMissing > 0 ? "\(match.missingCopies) · about \(PriceFormat.compact(missingValue))" : "\(match.missingCopies)")
                        .monospacedDigit()
                }
                .accessibilityIdentifier("finder-missing")
            }
            Section {
                Button(copied ? "Copied" : "Copy List", systemImage: copied ? "checkmark" : "doc.on.clipboard") { copy() }
                    .accessibilityIdentifier("finder-copy")
                if !missing.isEmpty {
                    BuyMenu(title: "Buy Missing Cards", lines: CardStore.lines(missing.map { ($0.name, $0.missing) }))
                }
            } footer: {
                Text("Paste the list into Decks › Add › Paste a Deck List to start from it.")
            }
            if !missing.isEmpty {
                Section("Missing · \(missing.count)") {
                    ForEach(missing) { line in row(line, count: line.missing) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Average Deck")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: match.slug) { await loadCards() }
    }

    private func row(_ line: CommanderMatch.Line, count: Int) -> some View {
        let card = cards[line.name]
        return HStack(spacing: 10) {
            CardArtThumb(artURL: card?.artCropURL, fallbackURL: card?.imageURL, width: 42, height: 30, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name).lineLimit(1)
                if let type = card?.typeLine { Text(type).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if count > 1 { Text("×\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            if let price = card?.price {
                Text(PriceFormat.tile(price)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func copy() {
        var lines = ["1 \(match.name)"]
        lines += match.lines.map { "\($0.needed) \($0.name)" }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }

    private func loadCards() async {
        let store = DeckStore.shared(for: modelContext.container)
        let names = match.missingLines.map(\.name)
        guard let found = try? await store.items(names: names) else { return }
        cards = found
    }
}
