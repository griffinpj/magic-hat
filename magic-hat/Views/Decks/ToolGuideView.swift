//
//  ToolGuideView.swift
//  magic-hat
//
//  The "i" behind each of the deck tools (Goldfish, Draw Odds, Mana
//  Base, Commander Finder): what the numbers are, how they are worked
//  out, and what they leave out — the same sheet of GuideRows the other
//  guides use, built from a `ToolGuide` so each tool declares its own
//  text beside its screen.
//

import SwiftUI

struct ToolGuide: Hashable {
    struct Row: Hashable {
        let icon: String
        let title: String
        let text: String
    }
    struct Section: Hashable {
        let title: String
        let rows: [Row]
    }

    let title: String
    let sections: [Section]
    /// Where the method comes from, as a footer.
    let source: String?
}

struct ToolGuideView: View {
    let guide: ToolGuide
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(guide.sections, id: \.self) { section in
                    Section {
                        ForEach(section.rows, id: \.self) { row in
                            GuideRow(icon: row.icon, title: row.title, text: row.text)
                        }
                    } header: {
                        Text(section.title)
                    }
                }
                if let source = guide.source {
                    Section {
                        Text(source)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(guide.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The toolbar's "i" and its sheet, applied by each tool screen.
struct ToolGuideButton: ViewModifier {
    let guide: ToolGuide
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("About", systemImage: "info.circle") { show = true }
                        .accessibilityIdentifier("tool-guide")
                }
            }
            .sheet(isPresented: $show) { ToolGuideView(guide: guide) }
    }
}

extension View {
    func toolGuide(_ guide: ToolGuide) -> some View { modifier(ToolGuideButton(guide: guide)) }
}

/// A percentage as the tools print it: whole, with a thin bar beside it.
struct OddsCell: View {
    let value: Double
    var tint: Color = .accentColor
    var width: CGFloat = 54

    var body: some View {
        HStack(spacing: 8) {
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: width, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: width * CGFloat(min(1, max(0, value))))
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}
