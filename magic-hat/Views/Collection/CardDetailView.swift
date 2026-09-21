//
//  CardDetailView.swift
//  magic-hat
//
//  Full detail screen for a card: a hero art header, gameplay text, and a
//  list of every printing (via Scryfall, grouped by set) with prices and an
//  indicator for the ones we own. Reachable from the card overlay's eye
//  action; reusable from Search later.
//
//  Pricing note: Scryfall provides only a single market price per finish
//  (prices.usd / usd_foil). LOW/MID tiers are TCGplayer-only and are mocked.
//

import SwiftUI
import SwiftData

struct CardDetailView: View {
    let item: CardItem

    @Query private var ownedEntries: [CollectionEntry]

    @State private var printings: [ScryfallCard] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedTab: Tab = .versions
    @State private var filterText = ""

    private enum Tab: Hashable { case versions, ruling }

    init(item: CardItem) {
        self.item = item
        var d = FetchDescriptor<CollectionEntry>()
        d.propertiesToFetch = [\.scryfallID]
        _ownedEntries = Query(d)
    }

    private var ownedIDs: Set<String> { Set(ownedEntries.map(\.scryfallID)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                gameplay
                tabBar
                if selectedTab == .versions { versionsSection } else { rulingSection }
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPrintings() }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            CardArtImage(urlString: item.artCropURL ?? item.imageURL)
                .frame(height: 320)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .center, endPoint: .bottom
                    )
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(.title2.bold())
                    Spacer()
                    if let cost = item.manaCost, !cost.isEmpty {
                        Text(cost.replacingOccurrences(of: "{", with: "")
                            .replacingOccurrences(of: "}", with: " ").trimmingCharacters(in: .whitespaces))
                            .font(.headline)
                    }
                }
                HStack {
                    Text(item.typeLine ?? "")
                        .font(.subheadline)
                    Spacer()
                    if let pt = item.powerToughness {
                        Text(pt).font(.headline)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(16)
        }
    }

    // MARK: Gameplay text

    @ViewBuilder private var gameplay: some View {
        if let text = item.oracleText, !text.isEmpty {
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(16)
        }
    }

    // MARK: Versions / Ruling tabs

    private var tabBar: some View {
        HStack(spacing: 12) {
            tabButton("Versions", .versions)
            tabButton("Ruling", .ruling)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func tabButton(_ title: String, _ tab: Tab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(
            selectedTab == tab ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
            in: Capsule()
        )
        .foregroundStyle(selectedTab == tab ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
        .overlay(Capsule().stroke(.tint, lineWidth: selectedTab == tab ? 0 : 1.5))
    }

    private var rulingSection: some View {
        ContentUnavailableView(
            "Rulings Coming Soon",
            systemImage: "text.book.closed",
            description: Text("Official rulings will appear here.")
        )
        .padding(.top, 40)
    }

    // MARK: Versions (printings)

    private var filteredGroups: [(set: String, code: String, cards: [ScryfallCard])] {
        let filtered = filterText.isEmpty ? printings : printings.filter {
            $0.setName.localizedCaseInsensitiveContains(filterText)
                || $0.set.localizedCaseInsensitiveContains(filterText)
        }
        let grouped = Dictionary(grouping: filtered) { $0.setName }
        return grouped.map { (set: $0.key, code: $0.value.first?.set.uppercased() ?? "", cards: $0.value) }
            .sorted { ($0.cards.first?.releasedAt ?? "") > ($1.cards.first?.releasedAt ?? "") }
    }

    @ViewBuilder private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("PRICING").font(.caption.weight(.bold)).foregroundStyle(.tint)
                Text("Market from Scryfall · Low/Mid mocked")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter sets", text: $filterText)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding()
            } else {
                ForEach(filteredGroups, id: \.set) { group in
                    setGroup(group)
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func setGroup(_ group: (set: String, code: String, cards: [ScryfallCard])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SetSymbolView(setCode: group.code, size: 22, tint: .primary)
                Text(group.set).font(.headline)
                Text("(\(group.code))").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            ForEach(group.cards) { card in
                PrintingRow(card: card, owned: ownedIDs.contains(card.id))
                    .padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Loading

    private func loadPrintings() async {
        guard printings.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let oracle: String
            if let o = item.oracleID {
                oracle = o
            } else {
                oracle = try await ScryfallClient.shared.card(id: item.scryfallID).oracleID ?? ""
            }
            guard !oracle.isEmpty else { loadError = "No printings found."; return }
            printings = try await ScryfallClient.shared.printings(oracleID: oracle)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Printing row

private struct PrintingRow: View {
    let card: ScryfallCard
    let owned: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CardImageView(
                urlString: card.bestImageURIs?.normal,
                aspectRatio: card.isLandscape ? 680.0/488.0 : 488.0/680.0,
                cornerRadius: 6,
                targetWidth: 60
            )
            .frame(width: 54)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("#\(card.collectorNumber)")
                        .font(.subheadline.weight(.medium))
                    if owned {
                        Label("In binder", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer()
                }
                priceGrid
            }
        }
        .padding(12)
        .background(
            owned ? AnyShapeStyle(Color.green.opacity(0.12)) : AnyShapeStyle(.quaternary),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.green.opacity(owned ? 0.5 : 0), lineWidth: 1)
        )
    }

    private var priceGrid: some View {
        HStack(alignment: .top, spacing: 16) {
            priceColumn(title: "Normal", market: card.prices?.usd)
            priceColumn(title: "Foil", market: card.prices?.usdFoil, foil: true)
        }
    }

    private func priceColumn(title: String, market: String?, foil: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(foil ? .orange : .primary)
            priceRow("LOW", nil, .red)
            priceRow("MID", nil, .green)
            priceRow("MKT", market.flatMap(Double.init), .blue)
        }
    }

    private func priceRow(_ label: String, _ value: Double?, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(color)
            Text(PriceFormat.string(value)).font(.caption2)
        }
    }
}

/// Fills its frame with card art (aspect-fill), decoded off-main.
private struct CardArtImage: View {
    let urlString: String?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: urlString) { await load() }
    }

    private func load() async {
        guard let urlString, !urlString.isEmpty else { return }
        let px = UIScreen.main.bounds.width * UIScreen.main.scale
        if let cached = ImageMemoryCache.shared.image(ImageMemoryCache.key(urlString, px)) {
            image = cached; return
        }
        image = try? await ImageLoader.shared.image(for: urlString, maxPixel: px)
    }
}
