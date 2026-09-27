//
//  SettingsView.swift
//  magic-hat
//
//  Settings, from the gear on the Collections tab: how prices and the grid
//  look, the language new cards are added in, the card data on this phone
//  (and a way to update it by hand), backups, and About. A sheet holding a
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

    private var sync: CatalogSyncController { .shared }
    private var hydrator: CardHydrationController { .shared }
    @State private var refreshingPrices = false
    @State private var pricesRefreshed: Int?

    private var currency: DisplayCurrency { DisplayCurrency(rawValue: currencyRaw) ?? .usd }

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                CardDataSection(onRefreshPrices: refreshPrices, refreshingPrices: refreshingPrices,
                                pricesRefreshed: pricesRefreshed)
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
            .accessibilityIdentifier("settings-language")
        } header: {
            Text("Display")
        } footer: {
            Text("Prices are Scryfall's \(currency.source). Card Language is what new cards are added in; you can change it for any card as you add it.")
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
            pricesRefreshed = await hydrator.refreshPrices(stale: ids, context: context)
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
        } header: {
            Text("Card Data")
        } footer: {
            Text("Search always asks Scryfall, so a new set shows up there the day it's released. The catalog on this phone — card details offline, deck imports, rulings — updates itself about once a week while charging on Wi-Fi. Your cards' prices refresh every 6 hours.")
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
