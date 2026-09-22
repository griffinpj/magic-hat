//
//  SearchFiltersView.swift
//  magic-hat
//
//  The filter sheet: one Form editing a draft CardSearchQuery, committed on
//  Done. Every control is the platform's own — toggles, menu pickers, pushed
//  searchable lists for long vocabularies, button-style toggles for short
//  multi-selects (rarity, finish), text fields with number formatting.
//  Reset is top-left, Done top-right; swiping the sheet down discards the
//  draft, as sheets do.
//
//  It edits a Binding<CardSearchQuery>, not the controller, so any screen
//  that owns a query can present it.
//

import SwiftUI

struct SearchFiltersView: View {
    @Binding var query: CardSearchQuery

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CardSearchQuery
    @State private var newOracle = ""

    init(query: Binding<CardSearchQuery>) {
        _query = query
        _draft = State(initialValue: query.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                optionsSection
                formatSection
                colorsSection
                typeLineSection
                oracleSection
                manaCostSection
                setsSection
                raritySection
                priceSection
                statsSection
                finishSection
                artistSection
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { draft.clearFilters() }
                        .disabled(!draft.hasFilters)
                        .accessibilityIdentifier("filters-reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        query = draft
                        dismiss()
                    }
                    .accessibilityIdentifier("filters-done")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: Options

    private var optionsSection: some View {
        Section {
            Toggle("Group Printings", isOn: $draft.groupPrintings)
                .accessibilityIdentifier("filter-group-printings")
            Toggle("Hide Tokens & Un-cards", isOn: $draft.excludeExtras)
            Picker("Language", selection: $draft.language) {
                Text("English").tag(String?.none)
                ForEach(Self.languages, id: \.code) { lang in
                    Text(lang.name).tag(Optional(lang.code))
                }
                Text("Any Language").tag(Optional("any"))
            }
        } footer: {
            Text("Group Printings shows one result per card instead of every printing.")
        }
    }

    private static let languages: [(code: String, name: String)] = [
        ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"), ("ru", "Russian"),
        ("zhs", "Chinese (Simplified)"), ("zht", "Chinese (Traditional)"),
    ]

    // MARK: Format

    private var formatSection: some View {
        Section("Format") {
            NavigationLink {
                MultiSelectListView(
                    title: "Legal In",
                    options: MagicFormat.allCases,
                    featured: MagicFormat.common,
                    selection: $draft.formats,
                    label: \.label
                )
            } label: {
                LabeledContent("Legal In", value: Self.summary(
                    MagicFormat.allCases.filter { draft.formats.contains($0) }.map(\.label)
                ))
            }
            .accessibilityIdentifier("filter-format")
        }
    }

    // MARK: Colors

    private var colorsSection: some View {
        Section {
            ColorPickerRow(colors: $draft.colors, colorless: $draft.colorless)
            Picker("Match", selection: $draft.colorMode) {
                ForEach(ColorMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Use Color Identity", isOn: $draft.useColorIdentity)
            Picker("Fewest Colors", selection: $draft.minColors) {
                Text("Any").tag(Int?.none)
                ForEach(0...5, id: \.self) { Text("\($0)").tag(Optional($0)) }
            }
            Picker("Most Colors", selection: $draft.maxColors) {
                Text("Any").tag(Int?.none)
                ForEach(0...5, id: \.self) { Text("\($0)").tag(Optional($0)) }
            }
        } header: {
            Text("Colors")
        } footer: {
            Text(colorFooter)
        }
    }

    private var colorFooter: String {
        switch draft.colorMode {
        case .exactly: return "Exactly: the chosen colors and no others."
        case .including: return "Including: at least the chosen colors, possibly more."
        case .atMost: return "At Most: only the chosen colors — what fits a commander of those colors."
        }
    }

    // MARK: Type line

    private var typeLineSection: some View {
        Section("Type Line") {
            NavigationLink {
                TypeLinePickerView(terms: $draft.typeLine)
            } label: {
                twoLine("Types", detail: draft.typeLine.isEmpty ? nil :
                    draft.typeLine.map { ($0.negated ? "not " : "") + $0.text }.joined(separator: ", "))
            }
            .accessibilityIdentifier("filter-types")
        }
    }

    // MARK: Rules text

    private var oracleSection: some View {
        Section {
            ForEach($draft.oracle) { $term in
                HStack(spacing: 10) {
                    Menu {
                        Button("Contains") { term.negated = false }
                        Button("Doesn't Contain") { term.negated = true }
                    } label: {
                        Text(term.negated ? "Not" : "Has")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(term.negated ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(term.negated ? .red : Color.accentColor)
                    }
                    TextField("Phrase", text: $term.text)
                }
            }
            .onDelete { draft.oracle.remove(atOffsets: $0) }

            TextField("Add a word or phrase", text: $newOracle)
                .onSubmit(addOraclePhrase)
                .submitLabel(.done)
            NavigationLink("Choose a Keyword…") {
                KeywordPickerView { keyword in draft.oracle.append(TextTerm(keyword)) }
            }
        } header: {
            Text("Rules Text")
        } footer: {
            Text("Each entry must appear in the card's text. Swipe an entry to remove it.")
        }
    }

    private func addOraclePhrase() {
        let t = newOracle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        draft.oracle.append(TextTerm(t))
        newOracle = ""
    }

    // MARK: Mana cost

    private var manaCostSection: some View {
        Section {
            HStack {
                TextField("2GW or {2}{G}{W}", text: $draft.manaCost)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .font(.body.monospaced())
                let normalized = CardSearchQuery.normalizedManaCost(draft.manaCost)
                if !normalized.isEmpty {
                    ManaCostView(cost: normalized, size: 18)
                }
            }
            ManaSymbolKeypad { symbol in draft.manaCost += "{\(symbol)}" } onDelete: {
                draft.manaCost = Self.droppingLastSymbol(draft.manaCost)
            }
            Picker("Match", selection: $draft.manaCostMatch) {
                ForEach(ManaCostMatch.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Mana Cost")
        } footer: {
            Text(draft.manaCostMatch == .contains
                 ? "Cards whose cost includes these symbols."
                 : "Cards with exactly this cost.")
        }
    }

    private static func droppingLastSymbol(_ cost: String) -> String {
        let normalized = CardSearchQuery.normalizedManaCost(cost)
        guard let open = normalized.lastIndex(of: "{") else { return "" }
        return String(normalized[..<open])
    }

    // MARK: Sets

    private var setsSection: some View {
        Section("Sets") {
            NavigationLink {
                SetPickerView(selection: $draft.sets)
            } label: {
                HStack {
                    Text("Sets")
                    Spacer()
                    if draft.sets.isEmpty {
                        Text("Any").foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(draft.sets.sorted().prefix(5), id: \.self) { code in
                                SetSymbolView(setCode: code, size: 18, tint: .secondary)
                            }
                            if draft.sets.count > 5 {
                                Text("+\(draft.sets.count - 5)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Rarity / finish

    private var raritySection: some View {
        Section("Rarity") {
            ToggleChips(options: CardRarity.allCases, selection: $draft.rarities, label: \.label, idPrefix: "filter-rarity")
        }
    }

    private var finishSection: some View {
        Section("Finish") {
            ToggleChips(options: CardFinishFilter.allCases, selection: $draft.finishes, label: \.label, idPrefix: "filter-finish")
        }
    }

    // MARK: Price

    private var priceSection: some View {
        Section("Price (USD)") {
            LabeledContent("Minimum") {
                TextField("Any", value: $draft.price.min, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Maximum") {
                TextField("Any", value: $draft.price.max, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: Stats

    private var statsSection: some View {
        Section("Stats") {
            ForEach(StatKind.allCases) { kind in
                StatRow(kind: kind, constraint: statBinding(kind))
            }
        }
    }

    /// Each stat has at most one constraint; a nil value removes it.
    private func statBinding(_ kind: StatKind) -> Binding<StatConstraint?> {
        Binding(
            get: { draft.stats.first { $0.stat == kind } },
            set: { new in
                draft.stats.removeAll { $0.stat == kind }
                if let new { draft.stats.append(new) }
            }
        )
    }

    // MARK: Artist

    private var artistSection: some View {
        Section("Artist") {
            TextField("Artist name", text: $draft.artist)
                .autocorrectionDisabled()
            NavigationLink("Choose an Artist…") {
                ArtistPickerView(selection: $draft.artist)
            }
        }
    }

    // MARK: Helpers

    private static func summary(_ names: [String]) -> String {
        if names.isEmpty { return "Any" }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }

    private func twoLine(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

// MARK: - Rows

/// W U B R G and colorless as tappable pips.
private struct ColorPickerRow: View {
    @Binding var colors: Set<ManaColor>
    @Binding var colorless: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ManaColor.allCases, id: \.self) { color in
                pip(ManaSymbol(color.rawValue), isOn: colors.contains(color)) {
                    if colors.contains(color) { colors.remove(color) } else { colors.insert(color); colorless = false }
                }
            }
            pip(ManaSymbol("C"), isOn: colorless) {
                colorless.toggle()
                if colorless { colors = [] }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func pip(_ symbol: ManaSymbol, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ManaSymbolView(symbol: symbol, size: 34)
                .opacity(isOn ? 1 : 0.35)
                .overlay {
                    if isOn { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-3) }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol.raw == "C" ? "Colorless" : (ManaColor(rawValue: symbol.raw)?.name ?? symbol.raw))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Short multi-select as button-style toggles in a row.
private struct ToggleChips<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Set<Option>
    let label: KeyPath<Option, String>
    let idPrefix: String

    var body: some View {
        // One line; scrolls rather than wrapping "Uncommon" mid-word.
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    Toggle(option[keyPath: label], isOn: Binding(
                        get: { selection.contains(option) },
                        set: { on in if on { selection.insert(option) } else { selection.remove(option) } }
                    ))
                    .toggleStyle(.button)
                    .buttonBorderShape(.capsule)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("\(idPrefix)-\(option[keyPath: label].lowercased().replacingOccurrences(of: "-", with: ""))")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

/// Buttons that type mana symbols into the cost field.
private struct ManaSymbolKeypad: View {
    let onTap: (String) -> Void
    let onDelete: () -> Void

    private let keys = ["W", "U", "B", "R", "G", "C", "X", "S", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    Button { onTap(key) } label: {
                        ManaSymbolView(symbol: ManaSymbol(key), size: 28)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key)
                }
                Button { onDelete() } label: {
                    Image(systemName: "delete.left")
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete last symbol")
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// "Power ≥ 4": an operator menu and a number; empty means no constraint.
private struct StatRow: View {
    let kind: StatKind
    @Binding var constraint: StatConstraint?

    var body: some View {
        LabeledContent(kind.label) {
            HStack(spacing: 8) {
                Picker("Comparison", selection: opBinding) {
                    ForEach(NumericOperator.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Any", value: valueBinding, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
            }
        }
    }

    private var opBinding: Binding<NumericOperator> {
        Binding(
            get: { constraint?.op ?? .equal },
            set: { op in
                if var c = constraint { c.op = op; constraint = c }
                else { constraint = nil; pendingOp = op }
            }
        )
    }

    @State private var pendingOp: NumericOperator = .equal

    private var valueBinding: Binding<Int?> {
        Binding(
            get: { constraint?.value },
            set: { value in
                if let value { constraint = StatConstraint(kind, constraint?.op ?? pendingOp, value) }
                else { constraint = nil }
            }
        )
    }
}

#Preview {
    SearchFiltersView(query: .constant(CardSearchQuery()))
}
