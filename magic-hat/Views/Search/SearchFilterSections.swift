//
//  SearchFilterSections.swift
//  magic-hat
//
//  The filter form's sections, editing a CardSearchQuery binding. Used two
//  ways: inline on the Search landing screen (edits the live query) and in
//  the Filters sheet over a draft. Nothing is pushed: long vocabularies —
//  types, keywords, sets, artists — are token fields that suggest inline as
//  you type, formats and rarities are chips, everything else is a toggle,
//  menu picker or number field.
//
//  Keyboard: every field has a Return key (the number fields use the
//  numbers-and-punctuation keyboard rather than a pad, which has none) with
//  a Done label, and the host Form dismisses on scroll. There is
//  deliberately no SwiftUI keyboard toolbar: it added seconds to the first
//  keyboard presentation on device. The FocusState remains so token fields
//  know when to show suggestions.
//
//  Suggestions appear as rows under their field, so the field has to be
//  near the top of what the keyboard leaves visible or the rows land
//  under the keys. A Form scrolls a focused field only far enough to show
//  it; with the host's `ScrollViewProxy`, focusing a token field scrolls
//  it to the top instead (Contacts and Mail do the same for a field
//  that grows), so its suggestions have the space above the keyboard.
//

import SwiftUI

/// Every text field in the form, so one FocusState can clear them all.
enum FilterField: Hashable {
    case types, oracle, manaCost, sets, priceMin, priceMax, artist
    case stat(StatKind)
}

/// Where the filters apply. A collection is searched in memory, so the
/// Scryfall-only options (grouping printings, hiding extras, sort) don't
/// appear there.
enum FilterContext {
    case scryfall
    case collection
}

struct SearchFilterSections: View {
    @Binding var query: CardSearchQuery
    @FocusState.Binding var focused: FilterField?
    var context: FilterContext = .scryfall
    /// Sort lives in the results toolbar too; on the landing screen it is
    /// only reachable here.
    var showsSort = true
    /// The host Form's proxy, so a focused token field can scroll to the
    /// top and leave room for its suggestions.
    var scrollProxy: ScrollViewProxy? = nil

    @State private var vocabulary = FilterVocabulary.shared
    @State private var showAllFormats = false

    var body: some View {
        optionsSection
            .task { await vocabulary.load() }
            .onChange(of: focused) { _, field in scrollToSuggestions(for: field) }
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

    /// The fields that suggest as you type.
    private static let suggestingFields: Set<FilterField> = [.types, .oracle, .sets, .artist]

    private func scrollToSuggestions(for field: FilterField?) {
        guard let field, Self.suggestingFields.contains(field), let scrollProxy else { return }
        Task { @MainActor in
            // After the keyboard has claimed its inset, so "top" is the top
            // of what remains.
            try? await Task.sleep(for: .milliseconds(120))
            guard focused == field else { return }
            withAnimation(.easeInOut(duration: 0.25)) { scrollProxy.scrollTo(field, anchor: .top) }
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        Section {
            if showsSort, context == .scryfall {
                Picker("Sort", selection: $query.sort) {
                    ForEach(SearchSort.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                }
                .onChange(of: query.sort) { _, _ in query.direction = nil }
            }
            Picker("Language", selection: $query.language) {
                Text(context == .collection ? "Any Language" : "English").tag(String?.none)
                if context == .collection { Text("English").tag(Optional("en")) }
                ForEach(Self.languages, id: \.code) { lang in
                    Text(lang.name).tag(Optional(lang.code))
                }
                if context == .scryfall { Text("Any Language").tag(Optional("any")) }
            }
            if context == .scryfall {
                Toggle("Group Printings", isOn: $query.groupPrintings)
                    .accessibilityIdentifier("filter-group-printings")
                Toggle("Hide Tokens & Un-cards", isOn: $query.excludeExtras)
            }
        } footer: {
            if context == .scryfall {
                Text("Group Printings shows one result per card instead of every printing.")
            }
        }
    }

    private static let languages: [(code: String, name: String)] = [
        ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"), ("ru", "Russian"),
        ("zhs", "Chinese (Simplified)"), ("zht", "Chinese (Traditional)"),
    ]

    // MARK: Format

    private var formatSection: some View {
        Section("Legal In") {
            FormatChips(formats: $query.formats, showAll: $showAllFormats)
                .equatable()
        }
    }

    // MARK: Colors

    private var colorsSection: some View {
        Section {
            ColorPickerRow(colors: $query.colors, colorless: $query.colorless)
                .equatable()
            Picker("Match", selection: $query.colorMode) {
                ForEach(ColorMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Use Color Identity", isOn: $query.useColorIdentity)
            Picker("Fewest Colors", selection: $query.minColors) {
                Text("Any").tag(Int?.none)
                ForEach(0...5, id: \.self) { Text("\($0)").tag(Optional($0)) }
            }
            Picker("Most Colors", selection: $query.maxColors) {
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
        switch query.colorMode {
        case .exactly: return "Exactly: the chosen colors and no others."
        case .including: return "Including: at least the chosen colors, possibly more."
        case .atMost: return "At Most: only the chosen colors — what fits a commander of those colors."
        }
    }

    // MARK: Type line

    private var typeLineSection: some View {
        Section {
            TermTokenRows(
                terms: $query.typeLine,
                placeholder: "Add a type: Creature, Dragon, Legendary…",
                focus: $focused, field: .types,
                suggest: { text in
                    vocabulary.typeMatches(text).map {
                        TokenSuggestion(text: $0.name, detail: $0.catalog.label,
                                        glyph: $0.catalog == .cardTypes ? $0.name.lowercased() : nil)
                    }
                }
            )
        } header: {
            Text("Type Line")
        } footer: {
            Text("Tap a chip to switch between is and is not, or remove it.")
        }
    }

    // MARK: Rules text

    private var oracleSection: some View {
        Section {
            TermTokenRows(
                terms: $query.oracle,
                placeholder: "Add a word or phrase: flying, draw a card…",
                focus: $focused, field: .oracle,
                suggest: { text in
                    vocabulary.keywordMatches(text).map {
                        TokenSuggestion(text: $0, detail: "Keyword",
                                        glyph: "ability-\($0.lowercased().replacingOccurrences(of: " ", with: "-"))")
                    }
                }
            )
        } header: {
            Text("Rules Text")
        } footer: {
            Text("Each entry must appear in the card's text. Return adds what you typed.")
        }
    }

    // MARK: Mana cost

    private var manaCostSection: some View {
        Section {
            HStack {
                TextField("2GW or {2}{G}{W}", text: $query.manaCost)
                    .focused($focused, equals: .manaCost)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .submitLabel(.done)
                    .font(.body.monospaced())
                let normalized = CardSearchQuery.normalizedManaCost(query.manaCost)
                if !normalized.isEmpty {
                    ManaCostView(cost: normalized, size: 18)
                }
            }
            ManaSymbolKeypad { symbol in query.manaCost += "{\(symbol)}" } onDelete: {
                query.manaCost = Self.droppingLastSymbol(query.manaCost)
            }
            .equatable()
            Picker("Match", selection: $query.manaCostMatch) {
                ForEach(ManaCostMatch.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Mana Cost")
        } footer: {
            Text(query.manaCostMatch == .contains
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
            SetTokenRows(selection: $query.sets, focus: $focused, vocabulary: vocabulary)
        }
    }

    // MARK: Rarity / finish

    private var raritySection: some View {
        Section("Rarity") {
            ToggleChips(options: CardRarity.allCases, selection: $query.rarities, label: \.label, idPrefix: "filter-rarity")
        }
    }

    private var finishSection: some View {
        Section("Finish") {
            ToggleChips(options: CardFinishFilter.allCases, selection: $query.finishes, label: \.label, idPrefix: "filter-finish")
        }
    }

    // MARK: Price

    private var priceSection: some View {
        Section("Price (USD)") {
            LabeledContent("Minimum") {
                TextField("Any", value: $query.price.min, format: .number.precision(.fractionLength(0...2)))
                    .focused($focused, equals: .priceMin)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Maximum") {
                TextField("Any", value: $query.price.max, format: .number.precision(.fractionLength(0...2)))
                    .focused($focused, equals: .priceMax)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: Stats

    private var statsSection: some View {
        Section("Stats") {
            ForEach(StatKind.allCases) { kind in
                StatRow(kind: kind, constraint: statBinding(kind), focus: $focused)
            }
        }
    }

    /// Each stat has at most one constraint; a nil value removes it.
    private func statBinding(_ kind: StatKind) -> Binding<StatConstraint?> {
        Binding(
            get: { query.stats.first { $0.stat == kind } },
            set: { new in
                query.stats.removeAll { $0.stat == kind }
                if let new { query.stats.append(new) }
            }
        )
    }

    // MARK: Artist

    private var artistSection: some View {
        Section("Artist") {
            SuggestingTextField(
                text: $query.artist, placeholder: "Artist name",
                focus: $focused, field: .artist,
                suggest: { vocabulary.artistMatches($0) }
            )
        }
    }

}

/// The format chips: the common eight, More reveals the rest (or all, once
/// an uncommon one is chosen). Equatable on its values so twenty-one
/// toggles aren't re-laid out on every unrelated change in the form.
private struct FormatChips: View, Equatable {
    @Binding var formats: Set<MagicFormat>
    @Binding var showAll: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.formats == rhs.formats && lhs.showAll == rhs.showAll
    }

    var body: some View {
        let expanded = showAll || formats.contains { !MagicFormat.common.contains($0) }
        let shown = expanded ? MagicFormat.allCases : MagicFormat.common
        FlowLayout {
            ForEach(shown) { format in
                Toggle(format.label, isOn: Binding(
                    get: { formats.contains(format) },
                    set: { on in if on { formats.insert(format) } else { formats.remove(format) } }
                ))
                .toggleStyle(.button)
                .buttonBorderShape(.capsule)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("filter-format-\(format.rawValue)")
            }
            if !expanded {
                Button("More…") { withAnimation(.snappy) { showAll = true } }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Token fields

struct TokenSuggestion: Identifiable, Hashable {
    let text: String
    var detail: String? = nil
    /// A Mana glyph name to show beside it (card types, keyword abilities).
    var glyph: String? = nil
    var id: String { text }
}

/// Chips for the chosen terms, a field to add more, and inline suggestions
/// while typing. Return adds the typed text as-is.
private struct TermTokenRows: View {
    @Binding var terms: [TextTerm]
    let placeholder: String
    @FocusState.Binding var focus: FilterField?
    let field: FilterField
    let suggest: (String) -> [TokenSuggestion]

    @State private var text = ""

    var body: some View {
        if !terms.isEmpty {
            FlowLayout {
                ForEach($terms) { $term in
                    TermChip(term: $term) { terms.removeAll { $0.id == term.id } }
                }
            }
            .padding(.vertical, 2)
        }
        TextField(placeholder, text: $text)
            .id(field)
            .focused($focus, equals: field)
            .submitLabel(.done)
            .autocorrectionDisabled()
            .onSubmit { add(text) }
        if focus == field, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            ForEach(suggest(text)) { suggestion in
                Button { add(suggestion.text) } label: {
                    HStack(spacing: 10) {
                        if let glyph = suggestion.glyph, ManaFont.glyph(named: glyph) != nil {
                            ManaGlyphView(name: glyph, size: 18).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                        Text(suggestion.text).foregroundStyle(.primary)
                        Spacer()
                        if let detail = suggestion.detail {
                            Text(detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func add(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if !terms.contains(where: { $0.text.caseInsensitiveCompare(t) == .orderedSame }) {
            terms.append(TextTerm(t))
        }
        text = ""
    }
}

/// A term chip whose menu flips is / is not or removes it.
private struct TermChip: View {
    @Binding var term: TextTerm
    let onRemove: () -> Void

    var body: some View {
        Menu {
            Button { term.negated = false } label: {
                Label("Is", systemImage: term.negated ? "" : "checkmark")
            }
            Button { term.negated = true } label: {
                Label("Is not", systemImage: term.negated ? "checkmark" : "")
            }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
        } label: {
            HStack(spacing: 4) {
                if term.negated {
                    Text("not").font(.caption.weight(.semibold))
                }
                Text(term.text)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(term.negated ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(term.negated ? Color.red : Color.accentColor)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("\(term.negated ? "Not " : "")\(term.text)")
    }
}

/// Set chips with their symbols, and a field suggesting sets by name or code.
private struct SetTokenRows: View {
    @Binding var selection: Set<String>
    @FocusState.Binding var focus: FilterField?
    let vocabulary: FilterVocabulary

    @State private var text = ""

    private var chosen: [ScryfallSet] {
        selection.sorted().map { code in
            vocabulary.sets.first { $0.code == code } ?? ScryfallSet(code: code, name: nil)
        }
    }

    var body: some View {
        if !selection.isEmpty {
            FlowLayout {
                ForEach(chosen) { set in
                    Button { selection.remove(set.code) } label: {
                        HStack(spacing: 5) {
                            SetSymbolView(setCode: set.code, size: 16, tint: Color.accentColor)
                            Text(set.code.uppercased())
                            Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(set.displayName)")
                }
            }
            .padding(.vertical, 2)
        }
        TextField("Add a set: name or code", text: $text)
            .id(FilterField.sets)
            .focused($focus, equals: .sets)
            .submitLabel(.done)
            .autocorrectionDisabled()
            .onSubmit {
                if let first = vocabulary.setMatches(text).first { add(first) }
            }
        if focus == .sets, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            ForEach(vocabulary.setMatches(text)) { set in
                Button { add(set) } label: {
                    HStack(spacing: 12) {
                        SetSymbolView(setCode: set.code, size: 22, tint: .primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(set.displayName).foregroundStyle(.primary)
                            Text("\(set.code.uppercased())\(set.releaseYear.map { " · \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection.contains(set.code.lowercased()) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
    }

    private func add(_ set: ScryfallSet) {
        selection.insert(set.code.lowercased())
        text = ""
    }
}

/// A single-value field (artist) with inline suggestions while typing.
private struct SuggestingTextField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState.Binding var focus: FilterField?
    let field: FilterField
    let suggest: (String) -> [String]

    var body: some View {
        TextField(placeholder, text: $text)
            .id(field)
            .focused($focus, equals: field)
            .submitLabel(.done)
            .autocorrectionDisabled()
        let matches = suggest(text).filter { $0 != text }
        if focus == field, !text.trimmingCharacters(in: .whitespaces).isEmpty, !matches.isEmpty {
            ForEach(matches, id: \.self) { match in
                Button {
                    text = match
                    focus = nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "paintbrush").foregroundStyle(.tint)
                        Text(match).foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

// MARK: - Rows

/// W U B R G and colorless as tappable pips. Equatable on its values so
/// the six glyph pips aren't re-rendered on every unrelated keystroke in
/// the form (a Binding otherwise always reads as changed).
private struct ColorPickerRow: View, Equatable {
    @Binding var colors: Set<ManaColor>
    @Binding var colorless: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.colors == rhs.colors && lhs.colorless == rhs.colorless
    }

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

/// Short multi-select as button-style toggles on one scrolling line.
private struct ToggleChips<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Set<Option>
    let label: KeyPath<Option, String>
    let idPrefix: String

    var body: some View {
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

/// Buttons that type mana symbols into the cost field. Stateless, so it
/// compares equal to itself and its nineteen glyphs render once.
private struct ManaSymbolKeypad: View, Equatable {
    let onTap: (String) -> Void
    let onDelete: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }

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
    @FocusState.Binding var focus: FilterField?

    @State private var pendingOp: NumericOperator = .equal

    var body: some View {
        LabeledContent(kind.label) {
            HStack(spacing: 8) {
                Picker("Comparison", selection: opBinding) {
                    ForEach(NumericOperator.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Any", value: valueBinding, format: .number)
                    .focused($focus, equals: .stat(kind))
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
            }
        }
    }

    private var opBinding: Binding<NumericOperator> {
        Binding(
            get: { constraint?.op ?? pendingOp },
            set: { op in
                if var c = constraint { c.op = op; constraint = c } else { pendingOp = op }
            }
        )
    }

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
