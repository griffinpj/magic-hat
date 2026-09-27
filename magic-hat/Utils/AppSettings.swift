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

nonisolated enum AppSettings {
    static let currencyKey = "settings.currency"
    static let cardLanguageKey = "settings.cardLanguage"
    static let gridColumnsKey = "settings.gridColumns"

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
}
