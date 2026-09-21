//
//  PriceFormat.swift
//  magic-hat
//

import Foundation

/// Formats Scryfall USD prices.
nonisolated enum PriceFormat {
    /// "$12.34"; nil shows a dash.
    static func string(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.2f", value)
    }

    /// Tight form for the grid, where cents on a $140 card are noise.
    static func compact(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    /// "+2.03 (+5.61%)" — signed, for value change since purchase.
    static func change(_ amount: Double, _ percent: Double) -> String {
        let sign = amount >= 0 ? "+" : "-"
        return String(format: "%@%.2f (%@%.1f%%)", sign, abs(amount), sign, abs(percent))
    }
}
