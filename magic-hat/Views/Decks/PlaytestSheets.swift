//
//  PlaytestSheets.swift
//  magic-hat
//
//  The sheets the playtest table opens: a zone to look through (graveyard,
//  exile) with what each card can do from there; the top of the library
//  to scry, surveil or rearrange; a library search; tokens to create; the
//  attackers to declare; the game log. Each takes values and hands every
//  change back to the table as a closure, so the table's one state (and
//  its undo) stays the only thing that moves cards.
//

import SwiftUI

// MARK: - Graveyard and exile

/// A zone's cards, newest first, three across. A tap opens the card in
/// the table's inspector, with what it can do from there: cast it
/// (flashback, from an adventure), return it, put it back on the
/// battlefield if it is a permanent, and so on.
struct PlaytestZoneSheet: View {
    let zone: PlaytestZone
    let cards: [PlaytestCard]
    let onInspect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if cards.isEmpty {
                    ContentUnavailableView("Empty", systemImage: zone == .exile ? "xmark.bin" : "archivebox",
                                           description: Text("Nothing is in the \(zone.label.lowercased())."))
                    .padding(.top, 60)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 14) {
                    ForEach(cards.reversed()) { card in
                        Button {
                            onInspect(card.id)
                        } label: {
                            VStack(spacing: 4) {
                                PlaytestCardView(card: card, width: 100)
                                if card.onAdventure {
                                    Text("On an adventure")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(card.name + (card.onAdventure ? ", on an adventure" : ""))
                        .accessibilityHint("Opens the card.")
                        .accessibilityIdentifier("playtest-zone-\(card.name)")
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(zone.label) · \(cards.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("playtest-zone-done")
                }
            }
        }
    }
}

// MARK: - The top of the library

/// Scry, surveil or look at the top N: each card with where it goes, the
/// ones staying on top in the order they're listed (drag to reorder).
struct PlaytestTopSheet: View {
    let look: PlaytestLook
    let onApply: ([(id: UUID, to: PlaytestTopDestination)]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cards: [PlaytestCard]
    @State private var destinations: [UUID: PlaytestTopDestination]

    init(look: PlaytestLook, cards: [PlaytestCard], onApply: @escaping ([(id: UUID, to: PlaytestTopDestination)]) -> Void) {
        self.look = look
        self.onApply = onApply
        _cards = State(initialValue: cards)
        _destinations = State(initialValue: Dictionary(uniqueKeysWithValues: cards.map { ($0.id, PlaytestTopDestination.top) }))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(cards) { card in
                        row(card)
                    }
                    .onMove { cards.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text(footer)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("\(look.label) \(cards.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onApply(cards.map { ($0.id, destinations[$0.id] ?? .top) })
                        dismiss()
                    }
                    .accessibilityIdentifier("playtest-top-done")
                }
            }
        }
    }

    private var footer: String {
        switch look {
        case .scry: return "Put any on the bottom; the rest stay on top in this order, the first on top."
        case .surveil: return "Put any into the graveyard; the rest stay on top in this order, the first on top."
        case .look: return "Each card goes where you choose. Cards left on top stay in this order, the first on top."
        }
    }

    private func row(_ card: PlaytestCard) -> some View {
        HStack(spacing: 12) {
            CardArtThumb(artURL: card.card.artCropURL, fallbackURL: card.card.imageURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).lineLimit(1)
                Text(card.face.kind).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if look.destinations.count <= 2 {
                Picker(card.name, selection: binding(card.id)) {
                    ForEach(look.destinations) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                Picker(card.name, selection: binding(card.id)) {
                    ForEach(look.destinations.filter { $0 != .battlefield || card.info.front.isPermanent }) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .accessibilityIdentifier("playtest-top-\(card.name)")
    }

    private func binding(_ id: UUID) -> Binding<PlaytestTopDestination> {
        Binding(get: { destinations[id] ?? .top }, set: { destinations[id] = $0 })
    }
}

// MARK: - Searching the library

/// Every card in the library, by type and name (the order is hidden, as a
/// search shows it), each with where it can go. The library is shuffled
/// after.
struct PlaytestSearchSheet: View {
    let cards: [PlaytestCard]
    let onTake: (UUID, PlaytestSearchDestination) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private struct Group: Identifiable {
        let id: String
        let cards: [(card: PlaytestCard, count: Int)]
    }

    private var groups: [Group] {
        let folded = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var byName: [String: (card: PlaytestCard, count: Int)] = [:]
        for card in cards where folded.isEmpty || card.name.lowercased().contains(folded) || card.face.typeLine.lowercased().contains(folded) {
            byName[card.card.name, default: (card, 0)].count += 1
        }
        let order = ["Land", "Creature", "Planeswalker", "Artifact", "Enchantment", "Battle", "Instant", "Sorcery", "Card"]
        return Dictionary(grouping: byName.values, by: { $0.card.info.front.kind })
            .map { Group(id: $0.key, cards: $0.value.sorted { $0.card.name < $1.card.name }) }
            .sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section("\(group.id == "Card" ? "Other" : group.id + "s") · \(group.cards.reduce(0) { $0 + $1.count })") {
                        ForEach(group.cards, id: \.card.id) { entry in
                            Menu {
                                destinations(entry.card)
                            } label: {
                                HStack(spacing: 12) {
                                    CardArtThumb(artURL: entry.card.card.artCropURL, fallbackURL: entry.card.card.imageURL)
                                    Text(entry.card.name).foregroundStyle(.primary)
                                    Spacer()
                                    if entry.count > 1 {
                                        Text("×\(entry.count)").foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .tint(.primary)
                            .accessibilityIdentifier("playtest-search-\(entry.card.name)")
                        }
                    }
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Card name or type")
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView.search(text: filter)
                }
            }
            .navigationTitle("Search Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    @ViewBuilder private func destinations(_ card: PlaytestCard) -> some View {
        ForEach(PlaytestSearchDestination.allCases.filter { !$0.isBattlefield || card.info.front.isPermanent }) { destination in
            Button(destination.label, systemImage: destination.systemImage) { take(card, destination) }
        }
    }

    private func take(_ card: PlaytestCard, _ destination: PlaytestSearchDestination) {
        onTake(card.id, destination)
        dismiss()
    }
}

// MARK: - Tokens

/// The tokens the deck makes (from its cards' Scryfall parts), the common
/// artifact tokens, and a creature token described by hand.
struct PlaytestTokenSheet: View {
    let deckTokens: [PlaytestTokenTemplate]
    let onCreate: (PlaytestTokenTemplate, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customName = ""
    @State private var customPower = 1
    @State private var customToughness = 1
    @State private var created = 0

    var body: some View {
        NavigationStack {
            List {
                if !deckTokens.isEmpty {
                    Section("This Deck’s Tokens") {
                        ForEach(deckTokens) { row($0) }
                    }
                }
                Section("Common") {
                    ForEach(PlaytestTokenTemplate.common) { row($0) }
                }
                Section {
                    TextField("Name (Zombie, Spirit…)", text: $customName)
                        .accessibilityIdentifier("playtest-token-custom-name")
                    Stepper("Power \(customPower)", value: $customPower, in: 0...20)
                    Stepper("Toughness \(customToughness)", value: $customToughness, in: 0...20)
                    Button("Create \(customPower)/\(customToughness) \(customName.isEmpty ? "Creature" : customName)") {
                        create(.custom(name: customName, power: customPower, toughness: customToughness), 1)
                    }
                    .accessibilityIdentifier("playtest-token-custom-create")
                } header: {
                    Text("Creature Token")
                }
            }
            .navigationTitle("Create Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("playtest-token-done")
                }
            }
            .sensoryFeedback(.success, trigger: created)
        }
    }

    private func row(_ token: PlaytestTokenTemplate) -> some View {
        HStack(spacing: 12) {
            Button {
                create(token, 1)
            } label: {
                HStack(spacing: 12) {
                    CardArtThumb(artURL: token.artCropURL, fallbackURL: token.imageURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(token.name).foregroundStyle(.primary)
                        Text(token.makers.isEmpty ? token.subtitle : token.subtitle + " · " + DeckTokenText.makers(token.makers))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("playtest-token-\(token.name)")
            Menu {
                ForEach([2, 3, 4, 5, 10], id: \.self) { n in
                    Button("Create \(n)") { create(token, n) }
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Create several \(token.name) tokens")
        }
    }

    private func create(_ token: PlaytestTokenTemplate, _ count: Int) {
        onCreate(token, count)
        created += 1
    }
}

// MARK: - Combat

/// Declare attackers: every untapped creature, those that can attack on;
/// summoning-sick ones listed apart, off, for when something gave haste.
struct PlaytestAttackSheet: View {
    let candidates: [PlaytestCard]
    let turn: Int
    let opponentLife: Int
    let onAttack: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID>

    init(candidates: [PlaytestCard], turn: Int, opponentLife: Int, onAttack: @escaping ([UUID]) -> Void) {
        self.candidates = candidates
        self.turn = turn
        self.opponentLife = opponentLife
        self.onAttack = onAttack
        _chosen = State(initialValue: Set(candidates.filter { !$0.isSummoningSick(on: turn) }.map(\.id)))
    }

    private var ready: [PlaytestCard] { candidates.filter { !$0.isSummoningSick(on: turn) } }
    private var sick: [PlaytestCard] { candidates.filter { $0.isSummoningSick(on: turn) } }

    private func damage(_ card: PlaytestCard) -> Int {
        max(0, card.power ?? 0) * (card.face.keywords.contains(.doubleStrike) ? 2 : 1)
    }
    private var total: Int { candidates.filter { chosen.contains($0.id) }.reduce(0) { $0 + damage($1) } }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    ContentUnavailableView("No Attackers", systemImage: "bolt.slash",
                                           description: Text("Untapped creatures without defender can attack."))
                }
                if !ready.isEmpty {
                    Section {
                        ForEach(ready) { row($0) }
                    } footer: {
                        Text("Attacking taps a creature unless it has vigilance.")
                    }
                }
                if !sick.isEmpty {
                    Section {
                        ForEach(sick) { row($0) }
                    } header: {
                        Text("Summoning Sick")
                    } footer: {
                        Text("These came in this turn. Turn one on only if something gave it haste.")
                    }
                }
            }
            .navigationTitle("Attack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaBar(edge: .bottom) {
                Button {
                    onAttack(candidates.map(\.id).filter(chosen.contains))
                    dismiss()
                } label: {
                    Text(chosen.isEmpty ? "Choose Attackers" : "Attack for \(total) · Opponent \(opponentLife) → \(opponentLife - total)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(chosen.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("playtest-attack-confirm")
            }
        }
    }

    private func row(_ card: PlaytestCard) -> some View {
        Toggle(isOn: Binding(get: { chosen.contains(card.id) },
                             set: { if $0 { chosen.insert(card.id) } else { chosen.remove(card.id) } })) {
            HStack(spacing: 12) {
                CardArtThumb(artURL: card.card.artCropURL, fallbackURL: card.card.imageURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name).lineLimit(1)
                    Text(detail(card)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier("playtest-attacker-\(card.name)")
    }

    private func detail(_ card: PlaytestCard) -> String {
        var parts: [String] = []
        if let p = card.power, let t = card.toughness { parts.append("\(p)/\(t)") } else { parts.append("Power unknown") }
        let keywords = card.face.keywords
        if keywords.contains(.doubleStrike) { parts.append("Double strike") }
        if keywords.contains(.vigilance) { parts.append("Vigilance") }
        if keywords.contains(.lifelink) { parts.append("Lifelink") }
        if keywords.contains(.haste) { parts.append("Haste") }
        if card.isCommander { parts.append("Commander") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The log

struct PlaytestLogSheet: View {
    let log: [PlaytestEvent]
    @Environment(\.dismiss) private var dismiss

    private var turns: [(turn: Int, events: [PlaytestEvent])] {
        Dictionary(grouping: log, by: \.turn)
            .map { ($0.key, $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.turn > $1.turn }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(turns, id: \.turn) { turn in
                    Section(turn.turn == 0 ? "Opening Hand" : "Turn \(turn.turn)") {
                        ForEach(turn.events) { event in
                            Label {
                                Text(event.text)
                            } icon: {
                                Image(systemName: PlaytestEventIcon.name(event.kind))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Game Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Life

/// −5 −1 [life] +1 +5, in a popover from the life total.
struct PlaytestLifeAdjuster: View {
    let title: String
    let life: Int
    var detail: String? = nil
    let onChange: (Int) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                step(-5); step(-1)
                Text("\(life)")
                    .font(.title.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(life)))
                    .frame(minWidth: 56)
                step(1); step(5)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func step(_ delta: Int) -> some View {
        Button(delta > 0 ? "+\(delta)" : "−\(-delta)") { onChange(delta) }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .monospacedDigit()
            .accessibilityIdentifier("playtest-life-\(delta)")
    }
}
