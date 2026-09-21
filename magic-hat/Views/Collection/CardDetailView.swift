//
//  CardDetailView.swift
//  magic-hat
//
//  Full detail screen for a card: a hero art header, gameplay text, and a
//  list of every printing (via Scryfall, grouped by set) with prices and an
//  indicator for the ones we own. Reachable from the card overlay's eye
//  action; reusable from Search later.
//
//  Pricing note: we show the one market price Scryfall publishes per finish
//  (prices.usd / usd_foil). No low/mid/market tiers — no provider we can
//  reach on-device has them (see CLAUDE.md).
//

import SwiftUI
import SwiftData

struct CardDetailView: View {
    let item: CardItem

    @Query private var ownedEntries: [CollectionEntry]
    @Query private var allRulings: [CardRuling]

    @State private var printings: [ScryfallCard] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedTab: Tab = .versions
    @State private var filterText = ""
    @State private var overlayIndex: Int?
    @State private var detailPush: CardItem?

    private enum Tab: Hashable { case versions, ruling }

    /// Cached, not computed: these were rebuilt on every body pass (and the
    /// owned Set once per printing row), which made the screen crawl.
    @State private var ownedIDs: Set<String> = []
    @State private var printingItems: [CardItem] = []

    private func rebuildOwned() {
        ownedIDs = Set(ownedEntries.map(\.scryfallID))
        rebuildPrintingItems()
    }

    private func rebuildPrintingItems() {
        printingItems = printings.map {
            CardItem(scryfallCard: $0, owned: ownedIDs.contains($0.id))
        }
    }

    init(item: CardItem) {
        self.item = item
        var d = FetchDescriptor<CollectionEntry>()
        d.propertiesToFetch = [\.scryfallID]
        _ownedEntries = Query(d)

        // Scoped to this card's oracle id so we never load the whole ruling
        // table just to show a handful of lines.
        let oracle = item.oracleID ?? ""
        _allRulings = Query(
            filter: #Predicate<CardRuling> { $0.oracleID == oracle },
            sort: \CardRuling.publishedAt
        )
    }


    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                gameplay
                legalityStrip
                tabBar
                if selectedTab == .versions { versionsSection } else { rulingSection }
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPrintings() }
        .onChange(of: ownedEntries, initial: true) { _, _ in rebuildOwned() }
        .onChange(of: filterText) { _, _ in rebuildGroups() }
        .overlay {
            if let index = overlayIndex, printingItems.indices.contains(index) {
                CardOverlayView(
                    items: printingItems,
                    index: index,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) { overlayIndex = nil }
                    },
                    onOpenDetail: { tapped in
                        // Keep the overlay so popping detail returns to it.
                        detailPush = tapped
                    }
                )
                .transition(.opacity)
            }
        }
        .navigationDestination(item: $detailPush) { pushed in
            CardDetailView(item: pushed)
        }
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

    /// Format legality and EDHREC rank — both already present in the Scryfall
    /// response we fetch, so they cost no extra request.
    @ViewBuilder private var legalityStrip: some View {
        let formats = item.legalFormats
        if !formats.isEmpty || item.edhrecRank != nil {
            VStack(alignment: .leading, spacing: 8) {
                if !formats.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(formats, id: \.self) { format in
                                Text(format.capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.green.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                if let rank = item.edhrecRank {
                    Text("EDHREC rank #\(rank)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
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

    /// Rulings come from the bulk `rulings` file, ingested at launch, so this
    /// works offline and costs no request.
    @ViewBuilder private var rulingSection: some View {
        let rulings = matchingRulings
        if rulings.isEmpty {
            ContentUnavailableView(
                "No Rulings",
                systemImage: "text.book.closed",
                description: Text(allRulings.isEmpty
                                  ? "Rulings arrive with the card catalog."
                                  : "This card has no official rulings.")
            )
            .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rulings) { ruling in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ruling.comment)
                            .font(.callout)
                        Text("\(ruling.source.capitalized) · \(ruling.publishedAt)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(16)
        }
    }

    private var matchingRulings: [CardRuling] {
        guard let oracleID = item.oracleID else { return [] }
        return allRulings
            .filter { $0.oracleID == oracleID }
            .sorted { $0.publishedAt < $1.publishedAt }
    }

    // MARK: Versions (printings)

    /// Cached rather than computed: this filtered, grouped and sorted every
    /// printing on each body pass — including on every keystroke in the filter
    /// field and on unrelated state changes.
    @State private var filteredGroups: [PrintingGroup] = []

    struct PrintingGroup: Identifiable {
        let setName: String
        let code: String
        let cards: [ScryfallCard]
        var id: String { setName }
    }

    private func rebuildGroups() {
        let filtered = filterText.isEmpty ? printings : printings.filter {
            $0.setName.localizedCaseInsensitiveContains(filterText)
                || $0.set.localizedCaseInsensitiveContains(filterText)
        }
        filteredGroups = Dictionary(grouping: filtered) { $0.setName }
            .map { PrintingGroup(setName: $0.key, code: $0.value.first?.set.uppercased() ?? "", cards: $0.value) }
            .sorted { ($0.cards.first?.releasedAt ?? "") > ($1.cards.first?.releasedAt ?? "") }
    }

    @ViewBuilder private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("PRICING").font(.caption.weight(.bold)).foregroundStyle(.tint)
                Text("Market prices from Scryfall")
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
                ForEach(filteredGroups) { group in
                    setGroup(group)
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func setGroup(_ group: PrintingGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SetSymbolView(setCode: group.code, size: 22, tint: .primary)
                Text(group.setName).font(.headline)
                Text("(\(group.code))").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            ForEach(group.cards) { card in
                PrintingRow(card: card, owned: ownedIDs.contains(card.id))
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let idx = printingItems.firstIndex(where: { $0.id == card.id }) {
                            withAnimation(.easeInOut(duration: 0.2)) { overlayIndex = idx }
                        }
                    }
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
            printings = try await PrintingsCache.shared.printings(oracleID: oracle)
            rebuildPrintingItems()
            rebuildGroups()
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
        HStack(spacing: 20) {
            priceColumn(title: "Normal", market: card.prices?.usd, foil: false)
            priceColumn(title: "Foil", market: card.prices?.usdFoil, foil: true)
        }
    }

    private func priceColumn(title: String, market: String?, foil: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(foil ? .orange : .secondary)
            Text(PriceFormat.string(market.flatMap(Double.init)))
                .font(.caption.weight(.medium))
        }
    }
}

/// Fills its frame with card art (aspect-fill), decoded off-main.
private struct CardArtImage: View {
    let urlString: String?
    @Environment(\.displayScale) private var displayScale
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
        // Hero is full-width; 1200px covers every phone at native scale.
        let px = min(1200, 430 * displayScale)
        if let cached = ImageMemoryCache.shared.image(ImageMemoryCache.key(urlString, px)) {
            image = cached; return
        }
        image = try? await ImageLoader.shared.image(for: urlString, maxPixel: px)
    }
}
