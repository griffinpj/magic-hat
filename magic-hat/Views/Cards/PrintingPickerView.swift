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
    @State private var printings: [ScryfallCard] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var search = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    private var filtered: [ScryfallCard] {
        guard !search.isEmpty else { return printings }
        return printings.filter {
            $0.setName.localizedCaseInsensitiveContains(search)
                || $0.set.localizedCaseInsensitiveContains(search)
                || $0.collectorNumber.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Couldn't load printings", systemImage: "wifi.slash", description: Text(error))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { card in
                            cell(card)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("Printing")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search sets")
        .task { await load() }
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
            printings = try await PrintingsCache.shared.printings(oracleID: oracle)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
