//
//  PreconBrowserView.swift
//  magic-hat
//
//  The Precons page of the Decks tab: every preconstructed deck MTGJSON
//  knows, grouped by release year, newest first, with a kind picker
//  (Commander, Challenger & Starter, Jumpstart, Theme & Intro, Everything)
//  and the tab's search field filtering by name, code or type. A row
//  opens the deck read-only (`PreconDeckView`), where it can be imported.
//  The list is the Sets page's shape, since it answers the same kind of
//  question: what was printed, when.
//

import SwiftUI

struct PreconBrowserView: View {
    /// The tab's search text.
    let filter: String
    let open: (DeckRoute) -> Void

    @State private var controller = PreconController.shared
    @AppStorage("decks.precons.kind") private var kindRaw = PreconKind.commander.rawValue
    @State private var sections: [PreconSection] = []

    private var kind: PreconKind { PreconKind(rawValue: kindRaw) ?? .commander }

    var body: some View {
        Group {
            switch controller.phase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Precons", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await controller.load(force: true) } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("precons-retry")
                }
            case .loaded where sections.isEmpty && !filter.isEmpty:
                ContentUnavailableView.search(text: filter)
            case .loaded:
                list
            }
        }
        .task { await controller.load() }
        .task(id: "\(controller.summaries.count)|\(kindRaw)|\(filter)") { await regroup() }
    }

    /// Tiles, two across, under pinned year headers — the Decks tab's
    /// own look, with each deck's lead card as its cover.
    private var list: some View {
        ScrollView {
            VStack(spacing: 12) {
            kindPicker
                .padding(.horizontal, 2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.decks) { deck in
                            Button { open(.precon(deck.fileName)) } label: {
                                PreconTile(deck: deck)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("precon-row-\(deck.fileName)")
                        }
                    } header: {
                        Text(section.year)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .background(Color(.systemGroupedBackground))
                    }
                }
            }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await controller.load(force: true) }
    }

    private var kindPicker: some View {
        HStack {
            Menu {
                Picker("Kind", selection: $kindRaw) {
                    ForEach(PreconKind.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                HStack(spacing: 6) {
                    Label(kind.label, systemImage: "line.3.horizontal.decrease.circle")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
            }
            .accessibilityIdentifier("precons-kind")
            Spacer()
            Text("\(sections.reduce(0) { $0 + $1.decks.count }) decks")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Grouping three thousand products is a few milliseconds; off the
    /// main actor all the same, since it runs per keystroke.
    private func regroup() async {
        let summaries = controller.summaries
        let kind = kind
        let filter = filter
        let grouped = await Task.detached(priority: .userInitiated) {
            PreconController.sections(summaries, kind: kind, filter: filter)
        }.value
        guard !Task.isCancelled else { return }
        sections = grouped
    }
}

/// A precon as a tile: its lead card's art under the name, the product
/// line and year, and its colours — the shape of the user's own deck
/// tiles, so the two pages read as one. The cover is read when the tile
/// appears (`PreconController.cover`); until then, and for a deck with
/// no art to show, the set's symbol on a tinted field.
private struct PreconTile: View {
    let deck: MTGJSONDeckSummary

    @State private var controller = PreconController.shared
    @State private var cover: PreconCover?
    /// Grows with Dynamic Type: a fixed 150 cut a two-line name off at the
    /// larger sizes.
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 150

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let art = cover?.artURL {
                CardArtImage(urlString: art)
            } else {
                Rectangle()
                    .fill(Color(.tertiarySystemFill))
                    .overlay {
                        SetSymbolView(setCode: deck.code, size: 44, tint: .secondary)
                            .offset(y: -18)
                    }
            }
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(deck.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text([deck.code.uppercased(), deck.releaseDate.map { String($0.prefix(4)) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let cover {
                        HStack(spacing: 2) {
                            ForEach(cover.colors, id: \.self) { color in
                                ManaSymbolView(symbol: ManaSymbol(color.rawValue), size: 13)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: deck.fileName) {
            cover = controller.covers[deck.fileName]
            if cover == nil { cover = await controller.cover(for: deck.fileName) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(deck.name), \(deck.type ?? "deck"), \(deck.code.uppercased())")
    }
}
