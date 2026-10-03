//
//  CardDetailView.swift
//  magic-hat
//
//  Full detail screen for a card, pushed inside the viewer's own stack:
//  the art as a hero, what the card does, where it is legal and how played,
//  and every printing (via Scryfall, grouped by set, newest first) with its
//  prices and what of it is owned; rulings on their own segment. Reachable
//  from the viewer's Details action; the printings open the same viewer.
//
//  Laid out in the order the questions come: what is it (the art, name,
//  cost, type, the printing it was opened on), what does it do (the rules
//  text, a card of its own), where does it go (one row of chips: mana
//  value, the formats it is legal in, its EDHREC rank), then Printings |
//  Rulings as a segmented control. The navigation title stays out of the
//  art — a name in white over busy art read badly — and appears once the
//  hero has scrolled away. Printings are grouped rows in the grouped
//  list's shape, one container per set, with the set's year in its
//  header; each row names its treatment (Borderless, Showcase, Extended
//  Art …) beside its number, shows both finishes' prices, and, when owned,
//  how many copies and in which finish. A chip filters to owned printings;
//  the field filters sets.
//
//  Pricing note: we show the one market price Scryfall publishes per finish
//  (prices.usd / usd_foil). No low/mid/market tiers — no provider we can
//  reach on-device has them (see CLAUDE.md).
//

import SwiftUI
import SwiftData

struct CardDetailView: View {
    let item: CardItem

    @Environment(\.modelContext) private var modelContext
    @Query private var allRulings: [CardRuling]

    @State private var printings: [ScryfallCard] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedTab: Tab = .versions
    @State private var filterText = ""
    @State private var ownedOnly = false
    @Environment(\.showsPrices) private var showsPrices
    /// The hero has scrolled away: the title moves into the bar.
    @State private var showsTitle = false
    @Namespace private var zoom
    /// The printing the viewer was opened on, and the one it is showing now.
    @State private var viewing: CardItem?
    @State private var viewingID: String?

    private enum Tab: Hashable { case versions, ruling }

    /// Cached, not computed: these were rebuilt on every body pass (and the
    /// owned Set once per printing row), which made the screen crawl.
    @State private var ownedIDs: Set<String> = []
    /// Copies owned per printing, and how many of those are foil.
    @State private var ownedCounts: [String: (copies: Int, foils: Int)] = [:]
    @State private var printingItems: [CardItem] = [] {
        didSet { printingList = CardItemList(printingItems) }
    }
    @State private var printingList = CardItemList()

    /// Which printings we own, fetched off-main *after* the push has
    /// animated. This used to be an unbounded @Query over every entry, run
    /// synchronously during the transition. The copies per printing come
    /// from the rows themselves, by the ids on screen.
    private func loadOwned() async {
        let store = CollectionStore.shared(for: modelContext.container)
        if let ids = try? await store.ownedScryfallIDs(stamp: .current), !Task.isCancelled {
            ownedIDs = ids
            rebuildPrintingItems()
            rebuildGroups()
        }
        let shown = printings.map(\.id).filter { ownedIDs.contains($0) }
        guard !shown.isEmpty, let rows = try? await store.ownedItems(scryfallIDs: shown), !Task.isCancelled else { return }
        var counts: [String: (copies: Int, foils: Int)] = [:]
        for row in rows where !row.inList {
            counts[row.scryfallID, default: (0, 0)].copies += row.quantity
            if row.finish != .normal { counts[row.scryfallID, default: (0, 0)].foils += row.quantity }
        }
        ownedCounts = counts
    }

    /// Off the main actor: a basic land has hundreds of printings, and this
    /// ran on arrival and again when ownership landed, under the push.
    private func rebuildPrintingItems() {
        let printings = self.printings
        let owned = ownedIDs
        itemsTask?.cancel()
        itemsTask = Task {
            let items = await Task.detached(priority: .userInitiated) {
                printings.map { CardItem(scryfallCard: $0, owned: owned.contains($0.id)) }
            }.value
            guard !Task.isCancelled else { return }
            printingItems = items
        }
    }
    @State private var itemsTask: Task<Void, Never>?

    init(item: CardItem) {
        self.item = item
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
                VStack(spacing: 16) {
                    gameplay
                    chipRow
                    segments
                    if selectedTab == .versions { versionsSection } else { rulingSection }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .background(Color(.systemGroupedBackground))
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.y > Self.heroHeight - 120 }) { _, past in
            if showsTitle != past { withAnimation(.easeInOut(duration: 0.15)) { showsTitle = past } }
        }
        .navigationTitle(showsTitle ? item.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPrintings() }
        .task(id: CollectionChangeTracker.shared.revision) { await loadOwned() }
        .onChange(of: filterText) { _, _ in rebuildGroups() }
        .onChange(of: ownedOnly) { _, _ in rebuildGroups() }
        .fullScreenCover(item: $viewing, onDismiss: { viewingID = nil }) { item in
            // Already on the detail screen; every printing shares it, so the
            // viewer has no Details action here.
            CardViewerView(items: printingList, currentID: $viewingID, showsDetail: false)
                .navigationTransition(.zoom(sourceID: viewingID ?? item.id, in: zoom))
        }
    }

    // MARK: Hero

    private static let heroHeight: CGFloat = 340

    /// The art, the name over its foot, and the printing this was opened
    /// on: set, number, rarity, artist — the one line the viewer's panel
    /// has and the art alone doesn't say.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            CardArtImage(urlString: item.artCropURL ?? item.imageURL, fallbackURL: item.imageURL)
                .frame(height: Self.heroHeight)
                .clipped()
                .overlay(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.78), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if let cost = item.manaCost, !cost.isEmpty {
                        ManaCostView(cost: cost, size: 20)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(item.typeLine ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let pt = item.powerToughness {
                        Text(pt).font(.headline.monospacedDigit())
                    } else if let loyalty = item.loyalty {
                        Label(loyalty, systemImage: "shield").font(.headline.monospacedDigit())
                    }
                }
                HStack(spacing: 6) {
                    if !item.setCode.isEmpty {
                        SetSymbolView(setCode: item.setCode, size: 14, tint: .white, rarity: item.rarity)
                    }
                    Text(printingLine)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Unfinity · #256 · Uncommon · Stephanie Buscema"
    private var printingLine: String {
        var parts: [String] = []
        if !item.setName.isEmpty { parts.append(item.setName) }
        if !item.collectorNumber.isEmpty { parts.append("#\(item.collectorNumber)") }
        if !item.rarity.isEmpty { parts.append(item.rarity.capitalized) }
        if let artist = item.artist, !artist.isEmpty { parts.append(artist) }
        return parts.joined(separator: " · ")
    }

    // MARK: Gameplay text

    @ViewBuilder private var gameplay: some View {
        if let text = item.oracleText, !text.isEmpty {
            OracleTextView(text: text, font: .body, symbolSize: 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
        }
    }

    /// One row of chips, scrolling: mana value, the formats it is legal in,
    /// its EDHREC rank — all from the Scryfall response already fetched.
    @ViewBuilder private var chipRow: some View {
        let formats = item.legalFormats
        let manaValue = item.manaCost.map { ManaSymbol.manaValue(of: $0) }
        if !formats.isEmpty || item.edhrecRank != nil || (manaValue ?? 0) > 0 {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if let manaValue, manaValue > 0 {
                        chip("MV \(manaValue)", icon: "circle.hexagonpath", tint: .secondary)
                    }
                    ForEach(formats, id: \.self) { format in
                        chip(format.capitalized, icon: "checkmark", tint: .green)
                    }
                    if let rank = item.edhrecRank {
                        chip("EDHREC #\(rank.formatted())", icon: "chart.bar", tint: .secondary)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func chip(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(tint == .secondary ? 0.12 : 0.15), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: Printings | Rulings

    private var segments: some View {
        Picker("Section", selection: $selectedTab.animation(.easeInOut(duration: 0.15))) {
            Text(printings.isEmpty ? "Printings" : "Printings · \(printings.count)").tag(Tab.versions)
            Text(allRulings.isEmpty ? "Rulings" : "Rulings · \(allRulings.count)").tag(Tab.ruling)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("detail-segments")
    }

    /// Rulings come from the bulk `rulings` file, ingested at launch, so this
    /// works offline and costs no request.
    @ViewBuilder private var rulingSection: some View {
        if allRulings.isEmpty {
            ContentUnavailableView(
                "No Rulings",
                systemImage: "text.book.closed",
                description: Text("This card has no official rulings, or they haven't arrived with the catalog yet.")
            )
            .padding(.top, 24)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(allRulings.enumerated()), id: \.element.id) { index, ruling in
                    VStack(alignment: .leading, spacing: 6) {
                        OracleTextView(text: ruling.comment, font: .callout, symbolSize: 14)
                        Text(Self.rulingDate(ruling.publishedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    if index < allRulings.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    /// "2024-05-07" → "7 May 2024", as Scryfall writes the date.
    private static func rulingDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Printings

    /// Cached rather than computed: this filtered, grouped and sorted every
    /// printing on each body pass — including on every keystroke in the filter
    /// field and on unrelated state changes.
    @State private var filteredGroups: [PrintingGroup] = []

    nonisolated struct PrintingGroup: Identifiable, Sendable {
        let setName: String
        let code: String
        let year: String
        let cards: [ScryfallCard]
        var id: String { setName }
    }

    /// Filter, group and sort off the main actor — per keystroke in the
    /// filter field, over every printing.
    private func rebuildGroups() {
        let printings = self.printings
        let text = filterText
        let owned = ownedOnly ? ownedIDs : nil
        groupsTask?.cancel()
        groupsTask = Task {
            let groups = await Task.detached(priority: .userInitiated) { Self.groups(of: printings, matching: text, owned: owned) }.value
            guard !Task.isCancelled else { return }
            filteredGroups = groups
        }
    }
    @State private var groupsTask: Task<Void, Never>?

    nonisolated private static func groups(of printings: [ScryfallCard], matching text: String, owned: Set<String>?) -> [PrintingGroup] {
        var filtered = text.isEmpty ? printings : printings.filter {
            $0.setName.localizedCaseInsensitiveContains(text) || $0.set.localizedCaseInsensitiveContains(text)
        }
        if let owned { filtered = filtered.filter { owned.contains($0.id) } }
        return Dictionary(grouping: filtered) { $0.setName }
            .map { group in
                let cards = group.value.sorted { CardItem.collectorValue($0.collectorNumber) < CardItem.collectorValue($1.collectorNumber) }
                return PrintingGroup(setName: group.key, code: cards.first?.set.uppercased() ?? "",
                                     year: String((cards.first?.releasedAt ?? "").prefix(4)), cards: cards)
            }
            .sorted { ($0.cards.first?.releasedAt ?? "") > ($1.cards.first?.releasedAt ?? "") }
    }

    /// The cheapest printing's price, for the header.
    private var lowestPrice: Double? {
        printings.compactMap { $0.prices?.price(foil: false, in: AppSettings.currency) }.min()
    }

    @ViewBuilder private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter sets", text: $filterText)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                    if !filterText.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill", action: clearFilter)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.tertiary)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                Toggle(isOn: $ownedOnly) {
                    Label("Owned", systemImage: "checkmark.seal")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(ownedIDs.isDisjoint(with: printings.map(\.id)))
                .accessibilityIdentifier("detail-owned-only")
            }
            .padding(.horizontal, 16)

            HStack(spacing: 6) {
                Text(printingsLine)
                Spacer()
                if showsPrices { Text("Market prices from Scryfall") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)

            if isLoading, printings.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding()
            } else if filteredGroups.isEmpty, !printings.isEmpty {
                Text(ownedOnly ? "None of this card's printings is in your collection." : "No set matches.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                // Lazy, and flattened: headers and rows are individual lazy
                // children, so only what is on screen loads its image or
                // rasterizes its set symbol. As a plain VStack every printing
                // (and every set symbol) was created during the push. Each
                // row draws its own share of the set's rounded container.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredGroups) { group in
                        setHeader(group)
                        ForEach(Array(group.cards.enumerated()), id: \.element.id) { index, card in
                            printingRow(card, position: RowPosition(index: index, count: group.cards.count))
                        }
                    }
                }
            }
        }
    }

    /// "4 printings in 2 sets · from $0.06", or what the filter leaves.
    private var printingsLine: String {
        let shown = filteredGroups.reduce(0) { $0 + $1.cards.count }
        guard !printings.isEmpty else { return isLoading ? "Loading printings…" : "" }
        var line = shown == printings.count
            ? "\(printings.count) \(printings.count == 1 ? "printing" : "printings") in \(filteredGroups.count) \(filteredGroups.count == 1 ? "set" : "sets")"
            : "\(shown) of \(printings.count) printings"
        if showsPrices, let low = lowestPrice, low > 0 { line += " · from \(PriceFormat.string(low))" }
        return line
    }

    private func setHeader(_ group: PrintingGroup) -> some View {
        HStack(spacing: 8) {
            SetSymbolView(setCode: group.code, size: 20, tint: .primary, rarity: group.cards.first?.rarity)
            Text(group.setName)
                .font(.headline)
                .lineLimit(1)
            Text(group.year.isEmpty ? group.code : "\(group.code) · \(group.year)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
    }

    private func printingRow(_ card: ScryfallCard, position: RowPosition) -> some View {
        PrintingRow(card: card, owned: ownedCounts[card.id], isOwned: ownedIDs.contains(card.id),
                    isCurrent: card.id == item.scryfallID, position: position, showsPrices: showsPrices)
            .padding(.horizontal, 16)
            .matchedTransitionSource(id: card.id, in: zoom)
            .contentShape(Rectangle())
            .onTapGesture {
                if let item = printingItems.first(where: { $0.id == card.id }) {
                    viewingID = item.id
                    viewing = item
                }
            }
    }

    private func clearFilter() { filterText.removeAll() }

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

/// Where a row sits in its set's container: which corners it rounds.
nonisolated struct RowPosition: Hashable, Sendable {
    let isFirst: Bool
    let isLast: Bool

    init(index: Int, count: Int) {
        isFirst = index == 0
        isLast = index == count - 1
    }

    var shape: UnevenRoundedRectangle {
        let r: CGFloat = 16
        return UnevenRoundedRectangle(topLeadingRadius: isFirst ? r : 0, bottomLeadingRadius: isLast ? r : 0,
                                      bottomTrailingRadius: isLast ? r : 0, topTrailingRadius: isFirst ? r : 0, style: .continuous)
    }
}

// MARK: - Printing row

/// One printing in its set's container: the card, its number and
/// treatment, both finishes' prices; when owned, the copies and finish
/// held, with a green mark; the printing the screen was opened on is
/// marked too.
private struct PrintingRow: View {
    let card: ScryfallCard
    let owned: (copies: Int, foils: Int)?
    let isOwned: Bool
    let isCurrent: Bool
    let position: RowPosition
    let showsPrices: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                CardImageView(
                    urlString: card.bestImageURIs?.normal,
                    aspectRatio: card.isLandscape ? 680.0/488.0 : 488.0/680.0,
                    cornerRadius: 4,
                    targetWidth: 60
                )
                .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("#\(card.collectorNumber)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        if let treatment = card.treatment {
                            Text(treatment)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        if isCurrent {
                            Text("Viewing")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    if showsPrices { prices } else { finishesLine }
                }
                Spacer(minLength: 8)
                if isOwned {
                    ownedMark
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if !position.isLast {
                Divider().padding(.leading, 70)
            }
        }
        .background(
            isOwned ? AnyShapeStyle(Color.green.opacity(0.10)) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
            in: position.shape
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("printing-\(card.set)-\(card.collectorNumber)")
    }

    /// With prices off: the finishes alone.
    private var finishesLine: some View {
        Text(CardFinish.fromScryfall(card.finishes).map(\.displayName).joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// "$0.14 · Foil $0.22" — only the finishes the printing comes in.
    private var prices: some View {
        let finishes = CardFinish.fromScryfall(card.finishes)
        let normal = card.prices?.price(foil: false, in: AppSettings.currency)
        let foil = card.prices?.price(foil: true, in: AppSettings.currency)
        return HStack(spacing: 10) {
            if finishes.contains(.normal) {
                Text(PriceFormat.string(normal)).fontWeight(.medium)
            }
            if finishes.contains(.foil) || finishes.contains(.etched) {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(LinearGradient(colors: [.pink, .orange, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(PriceFormat.string(foil)).fontWeight(.medium)
                }
                .accessibilityLabel("Foil \(PriceFormat.string(foil))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    /// "✓ ×2 · 1 foil"
    private var ownedMark: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label(owned.map { "×\($0.copies)" } ?? "Owned", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
                .monospacedDigit()
            if let owned, owned.foils > 0 {
                Text(owned.foils == owned.copies ? (owned.copies == 1 ? "foil" : "all foil") : "\(owned.foils) foil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .accessibilityLabel(owned.map { "In collection, \($0.copies) copies" } ?? "In collection")
    }
}

/// Fills its frame with card art (aspect-fill), decoded off-main. Shows the
/// already-decoded card image (from the grid/overlay cache) instantly while
/// the art crop — a URL nothing has fetched before — downloads.
struct CardArtImage: View {
    let urlString: String?
    var fallbackURL: String? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    /// Already decoded — the art itself, or the card from the grid or the
    /// viewer — read during the body so the hero is never grey for a frame.
    private var memoryImage: UIImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let art = ImageMemoryCache.shared.image(ImageMemoryCache.key(urlString, min(1200, 430 * displayScale))) {
            return art
        }
        guard let fallbackURL else { return nil }
        for width in [480.0, 150.0] {
            if let smaller = ImageMemoryCache.shared.image(ImageMemoryCache.key(fallbackURL, width * displayScale)) {
                return smaller
            }
        }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = image ?? memoryImage {
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
        if let fallbackURL {
            // Overlay size first, then grid size — whichever is already decoded.
            for width in [480.0, 150.0] {
                if let smaller = ImageMemoryCache.shared.image(
                    ImageMemoryCache.key(fallbackURL, width * displayScale)) {
                    image = smaller
                    break
                }
            }
        }
        if let art = try? await ImageLoader.shared.image(for: urlString, maxPixel: px) {
            image = art
        }
    }
}
