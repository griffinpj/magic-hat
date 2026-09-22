//
//  DataPolicy.swift
//  magic-hat
//
//  The freshness rules in one place, so the store, the hydrator and the
//  catalog sync can't disagree about what "stale" means.
//

import Foundation

nonisolated enum DataPolicy {
    /// Scryfall market prices for owned cards, refreshed via the cheap batched
    /// `/cards/collection` call.
    static let priceTTL: TimeInterval = 6 * 3600

    /// Scryfall rebuilds `default_cards` daily; re-downloading ~79MB every day
    /// is not worth it when owned-card prices already refresh every 6h. Take
    /// the bulk catalog at most weekly.
    static let catalogRefreshInterval: TimeInterval = 7 * 24 * 3600

    /// Rulings are ~5MB; daily is fine.
    /// Weekly, like the catalog. Scryfall rebuilds the file daily, so a
    /// daily interval meant re-ingesting ~170k rows on the first launch of
    /// every day — minutes of SQLite writes right when the user starts
    /// typing. Rulings change rarely enough for a week.
    static let rulingsRefreshInterval: TimeInterval = 7 * 24 * 3600
}
