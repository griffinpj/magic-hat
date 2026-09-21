//
//  CardCondition.swift
//  magic-hat
//
//  Condition and language vocabularies. Both are stored on CollectionEntry
//  as the raw strings ManaBox uses, so these are presentation helpers over
//  those strings rather than a schema change.
//

import Foundation

nonisolated enum CardCondition: String, CaseIterable, Identifiable, Sendable {
    case mint
    case nearMint = "near_mint"
    case lightlyPlayed = "lightly_played"
    case moderatelyPlayed = "moderately_played"
    case heavilyPlayed = "heavily_played"
    case damaged

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mint: return "Mint"
        case .nearMint: return "Near Mint"
        case .lightlyPlayed: return "Lightly Played"
        case .moderatelyPlayed: return "Moderately Played"
        case .heavilyPlayed: return "Heavily Played"
        case .damaged: return "Damaged"
        }
    }

    var short: String {
        switch self {
        case .mint: return "M"
        case .nearMint: return "NM"
        case .lightlyPlayed: return "LP"
        case .moderatelyPlayed: return "MP"
        case .heavilyPlayed: return "HP"
        case .damaged: return "DMG"
        }
    }

    /// Display for a raw stored value, tolerating values we don't model.
    static func label(for raw: String) -> String {
        CardCondition(rawValue: raw)?.displayName
            ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func shortLabel(for raw: String) -> String {
        CardCondition(rawValue: raw)?.short ?? raw.uppercased()
    }
}

nonisolated enum CardLanguage {
    /// Scryfall language codes, in the order players expect to see them.
    static let codes = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "ru", "zhs", "zht"]

    static func name(_ code: String) -> String {
        switch code.lowercased() {
        case "en": return "English"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "ru": return "Russian"
        case "zhs": return "Chinese (Simplified)"
        case "zht": return "Chinese (Traditional)"
        default: return code.uppercased()
        }
    }
}
