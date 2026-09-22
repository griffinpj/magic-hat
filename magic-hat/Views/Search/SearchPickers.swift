//
//  SearchPickers.swift
//  magic-hat
//
//  Pushed pickers for the long vocabularies behind the filter sheet:
//  formats, type line terms, sets, keywords, artists. All are searchable
//  Lists with checkmarks, the way Settings and Mail pick from lists, and
//  they read from ScryfallCatalogCache so the second open is instant and
//  offline.
//

import SwiftUI

// MARK: - Generic multi-select

struct MultiSelectListView<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    var featured: [Option] = []
    @Binding var selection: Set<Option>
    let label: KeyPath<Option, String>

    @State private var search = ""

    private func matches(_ o: Option) -> Bool {
        search.isEmpty || o[keyPath: label].localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        List {
            if search.isEmpty, !featured.isEmpty {
                Section("Common") { rows(featured) }
                Section("All") { rows(options.filter { !featured.contains($0) }) }
            } else {
                rows(options.filter(matches))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search)
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { selection = [] }
                }
            }
        }
    }

    private func rows(_ items: [Option]) -> some View {
        ForEach(items) { option in
            Button {
                if selection.contains(option) { selection.remove(option) } else { selection.insert(option) }
            } label: {
                HStack {
                    Text(option[keyPath: label]).foregroundStyle(.primary)
                    Spacer()
                    if selection.contains(option) {
                        Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                    }
                }
            }
            .accessibilityAddTraits(selection.contains(option) ? .isSelected : [])
        }
    }
}

// MARK: - Type line

/// Supertypes, card types and every subtype from Scryfall's catalogs. A
/// tap cycles a term: not used → is → is not → not used. Anything not in
/// the catalogs (a brand-new type) can be added from the search field.
struct TypeLinePickerView: View {
    @Binding var terms: [TextTerm]

    @State private var catalogs: [(ScryfallCatalog, [String])] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var search = ""

    var body: some View {
        List {
            if !terms.isEmpty {
                Section("Selected") {
                    ForEach(terms) { term in
                        HStack {
                            Text(term.text)
                            Spacer()
                            Text(term.negated ? "Is not" : "Is")
                                .font(.footnote)
                                .foregroundStyle(term.negated ? .red : .secondary)
                        }
                    }
                    .onDelete { terms.remove(atOffsets: $0) }
                }
            }
            if isLoading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let error {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            let query = search.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty, !allTypes.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
                Section {
                    Button("Add “\(query)”") { cycle(query); search = "" }
                }
            }
            ForEach(catalogs, id: \.0) { catalog, types in
                let shown = types.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                if !shown.isEmpty {
                    Section(catalog.label) {
                        ForEach(shown, id: \.self) { type in
                            row(type, icon: catalog == .cardTypes ? type.lowercased() : nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("Types")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Creature, Dragon, Legendary…")
        .task { await load() }
    }

    private var allTypes: [String] { catalogs.flatMap(\.1) }

    private func row(_ type: String, icon: String?) -> some View {
        let state = terms.first { $0.text.caseInsensitiveCompare(type) == .orderedSame }
        return Button { cycle(type) } label: {
            HStack(spacing: 10) {
                if let icon { ManaGlyphView(name: icon, size: 18).foregroundStyle(.secondary) }
                Text(type).foregroundStyle(.primary)
                Spacer()
                if let state {
                    if state.negated {
                        Label("Is not", systemImage: "minus.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                    }
                }
            }
        }
        .accessibilityValue(state.map { $0.negated ? "is not" : "is" } ?? "not used")
    }

    private func cycle(_ type: String) {
        if let i = terms.firstIndex(where: { $0.text.caseInsensitiveCompare(type) == .orderedSame }) {
            if terms[i].negated { terms.remove(at: i) } else { terms[i].negated = true }
        } else {
            terms.append(TextTerm(type))
        }
    }

    private func load() async {
        guard catalogs.isEmpty else { return }
        do {
            var loaded: [(ScryfallCatalog, [String])] = []
            for catalog in ScryfallCatalog.typeLine {
                let values = try await ScryfallCatalogCache.shared.catalog(catalog)
                loaded.append((catalog, values))
            }
            catalogs = loaded
        } catch {
            self.error = "Couldn't load types: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - Sets

struct SetPickerView: View {
    @Binding var selection: Set<String>

    @State private var sets: [ScryfallSet] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var search = ""

    /// Sets that are actual products, not tokens/promos/memorabilia.
    private static let hiddenTypes: Set<String> = ["token", "promo", "memorabilia", "minigame"]

    private var filtered: [ScryfallSet] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return sets.filter { set in
            !Self.hiddenTypes.contains(set.setType ?? "")
                && (q.isEmpty || (set.name ?? "").localizedCaseInsensitiveContains(q)
                    || set.code.localizedCaseInsensitiveContains(q))
        }
    }

    private var byYear: [(Int, [ScryfallSet])] {
        let groups = Dictionary(grouping: filtered) { $0.releaseYear ?? 0 }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        List {
            if !selection.isEmpty {
                Section("Selected") {
                    ForEach(sets.filter { selection.contains($0.code) }) { set in row(set) }
                }
            }
            if isLoading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let error {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            ForEach(byYear, id: \.0) { year, group in
                Section(year == 0 ? "Undated" : String(year)) {
                    ForEach(group) { set in row(set) }
                }
            }
        }
        .navigationTitle("Sets")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Set name or code")
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { Button("Clear") { selection = [] } }
            }
        }
        .task { await load() }
    }

    private func row(_ set: ScryfallSet) -> some View {
        let code = set.code.lowercased()
        return Button {
            if selection.contains(code) { selection.remove(code) } else { selection.insert(code) }
        } label: {
            HStack(spacing: 12) {
                SetSymbolView(setCode: set.code, size: 24, tint: .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.name ?? set.code).foregroundStyle(.primary)
                    Text("\(set.code.uppercased()) · \(set.cardCount ?? 0) cards")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selection.contains(code) {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
        }
    }

    private func load() async {
        guard sets.isEmpty else { return }
        do {
            sets = try await ScryfallCatalogCache.shared.sets()
        } catch {
            self.error = "Couldn't load sets: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - Keywords

/// Keyword abilities, actions and ability words — tap one to add it as a
/// rules-text term.
struct KeywordPickerView: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var groups: [(ScryfallCatalog, [String])] = []
    @State private var isLoading = true
    @State private var search = ""

    var body: some View {
        List {
            if isLoading { Section { ProgressView().frame(maxWidth: .infinity) } }
            let q = search.trimmingCharacters(in: .whitespaces)
            ForEach(groups, id: \.0) { catalog, words in
                let shown = words.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
                if !shown.isEmpty {
                    Section(catalog.label) {
                        ForEach(shown, id: \.self) { word in
                            Button {
                                onPick(word)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    ManaGlyphView(name: "ability-\(word.lowercased().replacingOccurrences(of: " ", with: "-"))", size: 18)
                                        .foregroundStyle(.secondary)
                                    Text(word).foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Keywords")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search)
        .task {
            guard groups.isEmpty else { return }
            var loaded: [(ScryfallCatalog, [String])] = []
            for catalog in [ScryfallCatalog.keywordAbilities, .keywordActions, .abilityWords] {
                if let words = try? await ScryfallCatalogCache.shared.catalog(catalog) {
                    loaded.append((catalog, words))
                }
            }
            groups = loaded
            isLoading = false
        }
    }
}

// MARK: - Artists

struct ArtistPickerView: View {
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss
    @State private var artists: [String] = []
    @State private var isLoading = true
    @State private var search = ""

    private var filtered: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return artists }
        return artists.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if isLoading { ProgressView().frame(maxWidth: .infinity) }
            ForEach(filtered, id: \.self) { artist in
                Button {
                    selection = artist
                    dismiss()
                } label: {
                    HStack {
                        Text(artist).foregroundStyle(.primary)
                        Spacer()
                        if artist == selection {
                            Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        .navigationTitle("Artist")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Artist name")
        .task {
            guard artists.isEmpty else { return }
            artists = (try? await ScryfallCatalogCache.shared.catalog(.artistNames)) ?? []
            isLoading = false
        }
    }
}
