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

    private var list: some View {
        List {
            Section {
                kindPicker
            }
            ForEach(sections) { section in
                Section(section.year) {
                    ForEach(section.decks) { deck in
                        Button { open(.precon(deck.fileName)) } label: {
                            PreconRow(deck: deck)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("precon-row-\(deck.fileName)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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

private struct PreconRow: View {
    let deck: MTGJSONDeckSummary

    var body: some View {
        HStack(spacing: 12) {
            SetSymbolView(setCode: deck.code, size: 26, tint: .primary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text([deck.code.uppercased(), deck.type, deck.releaseDate.flatMap(SetBrowsing.releaseDate)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
