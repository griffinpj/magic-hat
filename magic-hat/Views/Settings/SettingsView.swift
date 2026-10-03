//
//  SettingsView.swift
//  magic-hat
//
//  Settings, from the gear on the Collections tab: how prices and the grid
//  look, what an added or scanned card starts as, the card data on this
//  phone (and a way to update it by hand), what the app pulls over which
//  network and how often, the images it keeps, what deck analysis may ask
//  outside, backups, and About. A sheet holding a
//  grouped Form, the Settings app's own shape; every value lives in
//  AppSettings' UserDefaults keys, so each row is an @AppStorage binding
//  and nothing needs saving.
//
//  Changing the currency rebuilds every card on screen: the stores map
//  prices when they build items, so both trackers are bumped and each
//  screen refetches, as after any write.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @AppStorage(AppSettings.currencyKey) private var currencyRaw = DisplayCurrency.usd.rawValue
    @AppStorage(AppSettings.gridColumnsKey) private var gridColumns = GridDensity.standard.rawValue
    @AppStorage(AppSettings.cardLanguageKey) private var cardLanguage = "en"
    @AppStorage(AppSettings.showPricesKey) private var showPrices = true
    @AppStorage(AppSettings.defaultConditionKey) private var defaultCondition = CardCondition.nearMint.rawValue
    @AppStorage(AppSettings.defaultFinishKey) private var defaultFinish = CardFinish.normal.rawValue
    @AppStorage(AppSettings.priceRefreshKey) private var priceRefresh = PriceRefreshCadence.sixHours.rawValue
    @AppStorage(AppSettings.pricesOnCellularKey) private var pricesOnCellular = true
    @AppStorage(AppSettings.imagesOnCellularKey) private var imagesOnCellular = true
    @AppStorage(AppSettings.autoCatalogRefreshKey) private var autoCatalogRefresh = true
    @AppStorage(AppSettings.onlineAnalysisKey) private var onlineAnalysis = true
    @State private var imageBytes: Int64?
    @State private var clearingImages = false

    private var sync: CatalogSyncController { .shared }
    private var hydrator: CardHydrationController { .shared }
    @State private var refreshingPrices = false
    @State private var pricesRefreshed: Int?

    private var currency: DisplayCurrency { DisplayCurrency(rawValue: currencyRaw) ?? .usd }

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                addingSection
                CardDataSection(onRefreshPrices: refreshPrices, refreshingPrices: refreshingPrices,
                                pricesRefreshed: pricesRefreshed, autoCatalogRefresh: $autoCatalogRefresh)
                pricesSection
                imagesSection
                analysisSection
                Section {
                    NavigationLink {
                        BackupSettingsView()
                    } label: {
                        Label("Backup & Restore", systemImage: "externaldrive")
                    }
                    .accessibilityIdentifier("settings-backup")
                } footer: {
                    Text("Save everything you've entered to a file, restore from one, or back up to iCloud Drive on a schedule.")
                }
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About Magic Hat", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("settings-about")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings-done")
                }
            }
            .onChange(of: currencyRaw) { _, _ in
                // Items carry prices in the currency they were built in.
                CollectionChangeTracker.shared.bump()
                DeckChangeTracker.shared.bump()
            }
            // What counts as stale changed: the stores re-read the rows.
            .onChange(of: priceRefresh) { _, _ in CollectionChangeTracker.shared.bump() }
            .task { imageBytes = await Task.detached { ImageLoader.shared.diskUsage() }.value }
        }
    }

    private var displaySection: some View {
        Section {
            Picker(selection: $currencyRaw) {
                ForEach(DisplayCurrency.allCases) { currency in
                    Text("\(currency.label) (\(currency.symbol))").tag(currency.rawValue)
                }
            } label: {
                Label("Currency", systemImage: "banknote")
            }
            .accessibilityIdentifier("settings-currency")

            Picker(selection: $gridColumns) {
                ForEach(GridDensity.allCases) { density in
                    Text("\(density.label) · \(density.rawValue) across").tag(density.rawValue)
                }
            } label: {
                Label("Grid Size", systemImage: "square.grid.3x3")
            }
            .accessibilityIdentifier("settings-grid")

            Picker(selection: $cardLanguage) {
                ForEach(CardLanguage.codes, id: \.self) { code in
                    Text(CardLanguage.name(code)).tag(code)
                }
            } label: {
                Label("Card Language", systemImage: "character.bubble")
            }
            // Pushed, as the Settings app lists languages: eleven rows, and a
            // menu picker builds its whole menu on every update.
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("settings-language")

            Toggle(isOn: $showPrices) {
                Label("Show Prices", systemImage: "dollarsign.circle")
            }
            .accessibilityIdentifier("settings-show-prices")
        } header: {
            Text("Display")
        } footer: {
            Text("Prices are Scryfall's \(currency.source). Show Prices off keeps values off tiles, cards, the viewer and deck rows — for a table where they aren't wanted; the Stats pages still total them.")
        }
    }

    /// What a card starts as when it is added or scanned.
    private var addingSection: some View {
        Section {
            Picker(selection: $defaultCondition) {
                ForEach(CardCondition.allCases) { condition in
                    Text(condition.displayName).tag(condition.rawValue)
                }
            } label: {
                Label("Default Condition", systemImage: "hand.thumbsup")
            }
            .accessibilityIdentifier("settings-condition")
            Picker(selection: $defaultFinish) {
                Text("Normal").tag(CardFinish.normal.rawValue)
                Text("Foil").tag(CardFinish.foil.rawValue)
            } label: {
                Label("Default Finish", systemImage: "sparkles")
            }
            .accessibilityIdentifier("settings-finish")
        } header: {
            Text("Adding Cards")
        } footer: {
            Text("What the Add sheet and the scanner start with. A scan that reads a foil's ★ is foil whatever this says; a printing with no normal finish starts as what it has.")
        }
    }

    /// How often, and over what, prices are refreshed.
    private var pricesSection: some View {
        Section {
            Picker(selection: $priceRefresh) {
                ForEach(PriceRefreshCadence.allCases) { cadence in
                    Text(cadence.label).tag(cadence.rawValue)
                }
            } label: {
                Label("Refresh Prices", systemImage: "clock.arrow.2.circlepath")
            }
            .accessibilityIdentifier("settings-price-refresh")
            Toggle(isOn: $pricesOnCellular) {
                Label("Prices over Cellular", systemImage: "antenna.radiowaves.left.and.right")
            }
            .accessibilityIdentifier("settings-prices-cellular")
        } header: {
            Text("Prices")
        } footer: {
            Text("Owned cards' prices are refreshed through one small request per 75 cards when they are older than this. Manually leaves them until Refresh Prices Now. Off cellular, the refresh waits for Wi-Fi.")
        }
    }

    /// Card images: whether they stream on cellular, and the cache.
    private var imagesSection: some View {
        Section {
            Toggle(isOn: $imagesOnCellular) {
                Label("Images over Cellular", systemImage: "photo")
            }
            .accessibilityIdentifier("settings-images-cellular")
            Button {
                clearImages()
            } label: {
                HStack {
                    Label("Clear Image Cache", systemImage: "trash")
                    Spacer()
                    if clearingImages {
                        ProgressView().controlSize(.small)
                    } else if let imageBytes {
                        Text(ByteCountFormatter.string(fromByteCount: imageBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(clearingImages || imageBytes == 0)
            .accessibilityIdentifier("settings-clear-images")
        } header: {
            Text("Images")
        } footer: {
            Text("Card images stream from Scryfall as cards are shown and stay on the phone. Off cellular, only images already here are shown until Wi-Fi. Clearing frees the space; they stream back as needed.")
        }
    }

    /// What deck analysis may ask outside the phone.
    private var analysisSection: some View {
        Section {
            Toggle(isOn: $onlineAnalysis) {
                Label("Online Signals", systemImage: "antenna.radiowaves.left.and.right.circle")
            }
            .accessibilityIdentifier("settings-online-analysis")
        } header: {
            Text("Deck Analysis")
        } footer: {
            Text("With this on, a deck's analysis asks Commander Spellbook for combos, EDHREC for synergies, Recommander for the meta's picks and Scryfall for its tag lists — the deck's card names are sent to them. Off, the analysis reads the cards' own text only, and the Synergies screen shows only what is cached.")
        }
    }

    private func clearImages() {
        clearingImages = true
        Task {
            await ImageLoader.shared.clearCache()
            imageBytes = await Task.detached { ImageLoader.shared.diskUsage() }.value
            clearingImages = false
        }
    }

    /// Every owned card's price, now, through the batched call the 6-hour
    /// refresh uses.
    private func refreshPrices() {
        guard !refreshingPrices else { return }
        refreshingPrices = true
        pricesRefreshed = nil
        let context = modelContext
        Task {
            defer { refreshingPrices = false }
            let store = CollectionStore.shared(for: context.container)
            guard let all = try? await store.snapshot(collectionName: CollectionScope.allKey, sort: .name, stamp: .current) else { return }
            let ids = all.items.map(\.scryfallID)
            pricesRefreshed = await hydrator.refreshPrices(stale: ids, context: context, force: true)
        }
    }
}

/// The card catalog on this phone, when it was built, and the way to take
/// a newer one now — after checking, never blindly: the check reads the
/// manifest (a few KB) and only a newer build offers the download. The
/// update runs in place with the sync bar, not the first-launch screen:
/// the app is already usable on the catalog it has.
private struct CardDataSection: View {
    @Environment(\.modelContext) private var modelContext
    let onRefreshPrices: () -> Void
    let refreshingPrices: Bool
    let pricesRefreshed: Int?
    @Binding var autoCatalogRefresh: Bool

    private var sync: CatalogSyncController { .shared }

    var body: some View {
        Section {
            LabeledContent {
                Text(catalogDate)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Card Catalog", systemImage: "books.vertical")
            }
            .accessibilityIdentifier("settings-catalog")

            if sync.phase.isActive {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(sync.statusText.isEmpty ? "Working…" : sync.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                checkRow
            }

            Toggle(isOn: $autoCatalogRefresh) {
                Label("Update Automatically", systemImage: "arrow.triangle.2.circlepath.circle")
            }
            .accessibilityIdentifier("settings-auto-catalog")
            Toggle(isOn: Binding(get: { sync.allowCellular }, set: { sync.allowCellular = $0 })) {
                Label("Download over Cellular", systemImage: "antenna.radiowaves.left.and.right")
            }

            Button(action: onRefreshPrices) {
                HStack {
                    Label("Refresh Prices Now", systemImage: "arrow.clockwise")
                    Spacer()
                    if refreshingPrices {
                        ProgressView().controlSize(.small)
                    } else if let pricesRefreshed {
                        Text("\(pricesRefreshed.formatted()) updated").foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(refreshingPrices)
            .accessibilityIdentifier("settings-refresh-prices")

            NavigationLink {
                DataActivityView()
            } label: {
                HStack {
                    Label("Data Activity", systemImage: "list.bullet.clipboard")
                    Spacer()
                    if DataActivity.shared.isAnythingRunning {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .accessibilityIdentifier("settings-data-activity")
        } header: {
            Text("Card Data")
        } footer: {
            Text("Search always asks Scryfall, so a new set shows up there the day it's released. The catalog on this phone — card details offline, deck imports, rulings — updates itself about once a week while charging on Wi-Fi when Update Automatically is on; off, it waits for Check for Updates.")
        }
    }

    private var catalogDate: String {
        guard let built = sync.builtAt(.defaultCards) ?? sync.lastIngested(.defaultCards) else {
            return sync.catalogReady ? "Downloaded" : "Not downloaded"
        }
        return built.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder private var checkRow: some View {
        switch sync.lastCheck {
        case .available(let bytes, let builtAt)?:
            Button {
                Task { await sync.updateNow(container: modelContext.container) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Download Update", systemImage: "arrow.down.circle")
                    Text(availableLine(bytes: bytes, builtAt: builtAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings-download-update")
        default:
            Button {
                Task { await sync.checkForUpdates() }
            } label: {
                HStack {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if sync.isCheckingForUpdates {
                        ProgressView().controlSize(.small)
                    } else if case .upToDate? = sync.lastCheck {
                        Text("Up to date").foregroundStyle(.secondary)
                    } else if case .failed(let message)? = sync.lastCheck {
                        Text(message).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .disabled(sync.isCheckingForUpdates)
            .accessibilityIdentifier("settings-check-updates")
        }
    }

    private func availableLine(bytes: Int?, builtAt: Date?) -> String {
        var parts: [String] = []
        if let builtAt { parts.append("Built \(builtAt.formatted(date: .abbreviated, time: .omitted))") }
        if let bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        return parts.isEmpty ? "A newer catalog is available" : parts.joined(separator: " · ")
    }
}

#Preview {
    SettingsView()
}
