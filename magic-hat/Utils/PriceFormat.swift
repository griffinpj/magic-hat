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

    /// Totals: grouped, and no cents once it is in the thousands ("$55,350").
    static func whole(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 1000 ? 0 : 2)))
    }

    /// "+87%" / "−5.7%" — the change since purchase as a percentage alone,
    /// for the grid: one decimal under 10%, none above.
    static func percent(_ percent: Double) -> String {
        let sign = percent >= 0 ? "+" : "\u{2212}"
        let magnitude = abs(percent)
        return sign + String(format: magnitude < 10 ? "%.1f%%" : "%.0f%%", magnitude)
    }

    /// "+2.03 (+5.61%)" — signed, for value change since purchase.
    static func change(_ amount: Double, _ percent: Double) -> String {
        let sign = amount >= 0 ? "+" : "-"
        return String(format: "%@%.2f (%@%.1f%%)", sign, abs(amount), sign, abs(percent))
    }
}
