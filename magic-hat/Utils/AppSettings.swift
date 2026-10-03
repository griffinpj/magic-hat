//
//  AppSettings.swift
//  magic-hat
//
//  The user's preferences, in UserDefaults under one set of keys that the
//  Settings screen binds with @AppStorage and everything else reads here.
//  Nonisolated and read on demand: a price is formatted, a card mapped or
//  a query built on whatever thread is doing it, and UserDefaults is safe
//  to read from any of them. Hot loops (the store's row mapping) read once
//  and pass the value down rather than asking per card.
//

import Foundation

/// The currency prices are shown in. Scryfall reports two market prices
/// per printing: TCGplayer's in dollars and Cardmarket's trend in euros.
nonisolated enum DisplayCurrency: String, CaseIterable, Codable, Sendable, Identifiable {
    case usd, eur

    var id: String { rawValue }
    /// ISO 4217, as ManaBox writes `purchasePriceCurrency`.
    var code: String { rawValue.uppercased() }
    var symbol: String { self == .usd ? "$" : "€" }
    var label: String { self == .usd ? "US Dollar" : "Euro" }
    /// Where the number comes from, for the picker's footer.
    var source: String { self == .usd ? "TCGplayer market price" : "Cardmarket trend price" }
    /// Scryfall's search key for this currency (`usd>=5`, `order=eur`).
    var scryfallKey: String { rawValue }
}

/// How many cards across the collection and search grids.
nonisolated enum GridDensity: Int, CaseIterable, Sendable, Identifiable {
    case large = 2, standard = 3, compact = 4, dense = 5

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .large: return "Large"
        case .standard: return "Standard"
        case .compact: return "Compact"
        case .dense: return "Dense"
        }
    }
    /// A dense grid has no room for the two-line caption under each tile.
    var showsCaption: Bool { self != .dense }
}

/// How often owned cards' prices are refreshed through the batched call.
nonisolated enum PriceRefreshCadence: Int, CaseIterable, Sendable, Identifiable {
    case sixHours = 6, twelveHours = 12, daily = 24, manual = 0

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .sixHours: return "Every 6 Hours"
        case .twelveHours: return "Every 12 Hours"
        case .daily: return "Daily"
        case .manual: return "Manually"
        }
    }
    /// Nothing is ever stale on Manual.
    var interval: TimeInterval { rawValue == 0 ? .infinity : TimeInterval(rawValue) * 3600 }
}

nonisolated enum AppSettings {
    static let currencyKey = "settings.currency"
    static let cardLanguageKey = "settings.cardLanguage"
    static let gridColumnsKey = "settings.gridColumns"
    /// What an Add or a scan starts with.
    static let defaultConditionKey = "settings.defaultCondition"
    static let defaultFinishKey = "settings.defaultFinish"
    /// Prices on tiles, cards, the viewer and the detail screen. Off at a
    /// table, where values on screen aren't wanted.
    static let showPricesKey = "settings.showPrices"
    /// What the app pulls, and when.
    static let priceRefreshKey = "settings.priceRefreshHours"
    static let pricesOnCellularKey = "settings.pricesOnCellular"
    static let imagesOnCellularKey = "settings.imagesOnCellular"
    static let autoCatalogRefreshKey = "settings.autoCatalogRefresh"
    /// Deck analysis may ask EDHREC, Commander Spellbook, Recommander and
    /// Scryfall's tag lists (the deck's card names leave the phone).
    static let onlineAnalysisKey = "settings.onlineAnalysis"

    private static var defaults: UserDefaults { .standard }
    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    static var currency: DisplayCurrency {
        UserDefaults.standard.string(forKey: currencyKey).flatMap(DisplayCurrency.init(rawValue:)) ?? .usd
    }

    /// The language new cards are added in (a Scryfall code, "en").
    static var cardLanguage: String {
        let code = UserDefaults.standard.string(forKey: cardLanguageKey) ?? "en"
        return CardLanguage.codes.contains(code) ? code : "en"
    }

    static var gridDensity: GridDensity {
        GridDensity(rawValue: UserDefaults.standard.integer(forKey: gridColumnsKey)) ?? .standard
    }

    static var defaultCondition: String {
        let raw = defaults.string(forKey: defaultConditionKey) ?? ""
        return CardCondition(rawValue: raw)?.rawValue ?? CardCondition.nearMint.rawValue
    }

    static var defaultFinish: CardFinish {
        CardFinish(rawValue: defaults.string(forKey: defaultFinishKey) ?? "") ?? .normal
    }

    static var showPrices: Bool { bool(showPricesKey, default: true) }
    static var priceRefresh: PriceRefreshCadence {
        defaults.object(forKey: priceRefreshKey) == nil ? .sixHours
            : (PriceRefreshCadence(rawValue: defaults.integer(forKey: priceRefreshKey)) ?? .sixHours)
    }
    static var pricesOnCellular: Bool { bool(pricesOnCellularKey, default: true) }
    static var imagesOnCellular: Bool { bool(imagesOnCellularKey, default: true) }
    static var autoCatalogRefresh: Bool { bool(autoCatalogRefreshKey, default: true) }
    static var onlineAnalysis: Bool { bool(onlineAnalysisKey, default: true) }
}
