//
//  PrintingPickerView.swift
//  magic-hat
//
//  Pushed from the Add sheet: every printing of the card, as a searchable
//  3-wide grid. Uses PrintingsCache, so a card whose detail screen (or
//  overlay) has been visited opens instantly and offline.
//

import SwiftUI

struct PrintingPickerView: View {
    let oracleID: String?
    let fallbackScryfallID: String
    let selectedID: String
    let onPick: (PrintingSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Every printing, behind a reference: a basic land has hundreds, and
    /// an array in state is compared element by element on updates.
    @State private var printings = PrintingIndex([])
    /// What the field leaves, in order — plain ids, what the grid iterates.
    @State private var shownIDs: [String] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var search = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    /// Filtered off the main actor per keystroke (a locale-aware match over
    /// three fields of every printing).
    private func refilter() async {
        let all = printings, text = search
        let ids = await Task.detached(priority: .userInitiated) { all.ids(matching: text) }.value
        guard !Task.isCancelled else { return }
        if ids != shownIDs { shownIDs = ids }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Couldn't Load Printings", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(shownIDs, id: \.self) { id in
                            if let card = printings.card(id) { cell(card) }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("Printing")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Set name or code")
        .task { await load() }
        .task(id: search) { await refilter() }
    }

    private func cell(_ card: ScryfallCard) -> some View {
        let isSelected = card.id == selectedID
        return Button {
            onPick(PrintingSelection(card: card))
            dismiss()
        } label: {
            VStack(spacing: 6) {
                CardImageView(
                    urlString: card.bestImageURIs?.normal,
                    aspectRatio: card.isLandscape ? 680.0 / 488.0 : 488.0 / 680.0,
                    cornerRadius: 8,
                    targetWidth: 130
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 3)
                    }
                }
                HStack(spacing: 4) {
                    SetSymbolView(setCode: card.set, size: 14, tint: .primary, rarity: card.rarity)
                    Text("\(card.set.uppercased()) #\(card.collectorNumber)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Text(card.setName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.setName) #\(card.collectorNumber)")
    }

    private func load() async {
        defer { isLoading = false }
        do {
            var oracle = oracleID ?? ""
            if oracle.isEmpty {
                oracle = try await ScryfallClient.shared.card(id: fallbackScryfallID).bestOracleID ?? ""
            }
            guard !oracle.isEmpty else { error = "This card has no oracle id."; return }
            printings = PrintingIndex(try await PrintingsCache.shared.printings(oracleID: oracle))
            await refilter()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A card's printings, looked up by id. Immutable, so it crosses to the
/// filter's detached task as is.
nonisolated private final class PrintingIndex: Sendable {
    let cards: [ScryfallCard]
    private let byID: [String: ScryfallCard]

    init(_ cards: [ScryfallCard]) {
        self.cards = cards
        byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func card(_ id: String) -> ScryfallCard? { byID[id] }

    func ids(matching text: String) -> [String] {
        guard !text.isEmpty else { return cards.map(\.id) }
        return cards.filter {
            $0.setName.localizedCaseInsensitiveContains(text)
                || $0.set.localizedCaseInsensitiveContains(text)
                || $0.collectorNumber.localizedCaseInsensitiveContains(text)
        }.map(\.id)
    }
}
