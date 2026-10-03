//
//  DeckProposeView.swift
//  magic-hat
//
//  "What would I cut for these?" — the user searches, picks a card, and
//  it is weighed against the deck: swap it in for a named card (with the
//  deck re-scored), add it while the list is short, or not clearly better
//  than the weakest card it would replace. A land is weighed against the
//  lands, a spell against the spells (DeckPlan.propose), so the answers
//  agree with Suggested Swaps.
//
//  One thing on screen at a time. Typing shows results and nothing else;
//  picking one clears the search and returns to the picks, where the card
//  just picked leads with its verdict — the two used to share one list,
//  and the verdict landed above the fold of the results being read. Each
//  pick is a card of its own: what comes in, what goes out, what that
//  does to the deck, and one button. The planner's cut is a default: the
//  out side is a menu of the next-weakest cards, and a pick that beats
//  nothing can still be swapped in by choosing what leaves.
//
//  A sheet, from the Swaps screen and the deck's "…" menu. Search is
//  Scryfall's, narrowed to the commander's identity when there is one.
//

import SwiftUI
import SwiftData

struct DeckProposeView: View {
    let deckID: UUID
    let controller: DeckAnalysisController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var session: DeckAddSession
    @State private var snapshot: DeckSnapshot?
    @State private var search = SearchController()
    @State private var searchText = ""
    @State private var searchPresented = false
    /// Newest first: the card just picked is the one being asked about.
    @State private var picks: [CardItem] = []
    @State private var verdicts: [String: DeckProposal] = [:]
    /// The card the user chose to cut for a pick, over the planner's.
    @State private var chosenCut: [String: String] = [:]
    @State private var isJudging = false
    @State private var applied = 0
    @State private var error: String?
    @State private var viewer: CardViewerSession?
    @Namespace private var zoom

    private var deckTracker: DeckChangeTracker { .shared }
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    init(deckID: UUID, controller: DeckAnalysisController, context: ModelContext) {
        self.deckID = deckID
        self.controller = controller
        _session = State(initialValue: DeckAddSession(deckID: deckID, context: context))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Try Cards")
                .navigationSubtitle(snapshot?.name ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, isPresented: $searchPresented,
                            placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a card to try")
                .onChange(of: searchText) { _, text in
                    search.query = query(text)
                    search.scheduleRun()
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("propose-done")
                    }
                }
                .sensoryFeedback(.success, trigger: applied)
                .alert("Couldn't Update Deck", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(error ?? "") }
                .task(id: deckTracker.revision) { await load() }
                .fullScreenCover(item: $viewer) { v in
                    CardViewerView(items: v.items, currentID: Bindable(v).currentID, deck: v.deck)
                        .navigationTransition(.zoom(sourceID: v.currentID ?? "", in: zoom))
                }
                // Judged again whenever the picks or the list change.
                .task(id: "\(picks.map(\.id).joined(separator: ","))|\(controller.listHash)|\(controller.analysis != nil)") {
                    await judge()
                }
        }
    }

    @ViewBuilder private var content: some View {
        if isSearching {
            results
        } else if picks.isEmpty {
            ContentUnavailableView {
                Label("What Would It Replace?", systemImage: "arrow.left.arrow.right")
            } description: {
                Text("Search for a card you're thinking about. It is weighed against this deck: what it would take the place of, what that does to the deck's scores, or why it wouldn't make the cut.")
            } actions: {
                Button("Search Cards") { searchPresented = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("propose-start")
            }
        } else {
            pickList
        }
    }

    // MARK: Picks

    private var pickList: some View {
        List {
            Section {
                ForEach(picks) { card in
                    ProposalCard(card: card, proposal: verdicts[card.id], chosen: chosenCut[card.id],
                                 judging: isJudging && verdicts[card.id] == nil,
                                 locked: snapshot?.isLocked ?? true, zoom: zoom,
                                 onOpen: { open(card, in: picks) },
                                 onOpenCut: { cut in open(cut, in: [cut]) },
                                 onChoose: { rowID in chosenCut[card.id] = rowID },
                                 onApply: { apply(card) },
                                 onRemove: { remove(card) })
                }
            } header: {
                HStack {
                    Text(picks.count == 1 ? "1 Card" : "\(picks.count) Cards")
                    Spacer()
                    if isJudging { ProgressView().controlSize(.mini) }
                }
            } footer: {
                Text("A spell is weighed against the deck's spells, a land against its lands. The weakest comes out when the new card is clearly better; tap what goes out to choose another.")
            }
        }
        .listStyle(.insetGrouped)
        .listRowSpacing(10)
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        List {
            switch search.phase {
            case .searching where search.results.isEmpty:
                HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            default:
                if search.results.isEmpty {
                    Text("No cards match.").foregroundStyle(.secondary)
                }
                ForEach(search.results.prefix(60)) { card in
                    resultRow(card)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    private func resultRow(_ card: CardItem) -> some View {
        let picked = picks.contains { $0.id == card.id }
        return HStack(spacing: 8) {
            Button { open(card, in: Array(search.results.prefix(60))) } label: {
                CardRowLead(item: card, zoom: zoom) {
                    Text(card.typeLine ?? card.setName)
                }
            }
            .buttonStyle(.plain)
            Button {
                pick(card)
            } label: {
                Text(picked ? "Picked" : "Try")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(picked)
            .accessibilityLabel(picked ? "\(card.name), picked" : "Try \(card.name)")
            .accessibilityIdentifier("propose-pick-\(card.name)")
        }
    }

    // MARK: Work

    private func query(_ text: String) -> CardSearchQuery {
        var q = CardSearchQuery()
        q.text = text
        q.sort = .edhrec
        if let identity = session.identityFilter {
            q.useColorIdentity = true
            if identity.isEmpty { q.colorless = true } else { q.colors = Set(identity); q.colorMode = .atMost }
        }
        return q
    }

    /// Onto the picks, at the top, and back to them: the verdict is what
    /// the user picked the card to see.
    private func pick(_ card: CardItem) {
        withAnimation {
            picks.removeAll { $0.id == card.id }
            picks.insert(card, at: 0)
        }
        searchText = ""
        searchPresented = false
    }

    private func remove(_ card: CardItem) {
        withAnimation { picks.removeAll { $0.id == card.id } }
        chosenCut[card.id] = nil
    }

    private func load() async {
        let store = DeckStore.shared(for: modelContext.container)
        if let fetched = try? await store.snapshot(deckID: deckID), !Task.isCancelled {
            snapshot = fetched
            session.update(from: fetched)
            controller.refresh(snapshot: fetched, container: modelContext.container)
        }
    }

    private func judge() async {
        guard !picks.isEmpty else { verdicts = [:]; return }
        isJudging = true
        defer { isJudging = false }
        // A short pause absorbs a burst of taps.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let result = await controller.propose(picks), !Task.isCancelled else { return }
        verdicts = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A chosen cut that is no longer on offer (the list changed) lapses.
        for (id, rowID) in chosenCut where verdicts[id]?.options.contains(where: { $0.rowID == rowID }) != true {
            chosenCut[id] = nil
        }
    }

    private func open(_ card: CardItem, in cards: [CardItem]) {
        viewer = CardViewerSession(items: cards, currentID: card.id, deck: session)
    }

    /// The pick goes onto the mainboard; one copy of what it replaces —
    /// the user's choice, else the planner's — comes off.
    private func apply(_ card: CardItem) {
        guard let proposal = verdicts[card.id] else { return }
        do {
            switch proposal.verdict {
            case .alreadyInDeck, .outsideIdentity:
                return
            case .add:
                break
            case .swap, .notBetter:
                guard let rowID = ProposalCard.cut(for: proposal, chosen: chosenCut[card.id])?.rowID,
                      let outID = UUID(uuidString: rowID) else { return }
                let current = snapshot?.playedItems.first { $0.id == outID }?.quantity ?? 1
                try DeckEditController.setQuantity(deckCardID: outID, current - 1, context: modelContext)
            }
            try session.setQuantity(card, session.quantity(of: card) + 1)
            chosenCut[card.id] = nil
            applied += 1
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A pick and its verdict, as one card: what comes in, what goes out (a
/// menu of the alternatives), what that does to the deck, and the button
/// that does it.
private struct ProposalCard: View {
    let card: CardItem
    let proposal: DeckProposal?
    /// The row id of the cut the user chose, over the planner's.
    let chosen: String?
    let judging: Bool
    let locked: Bool
    let zoom: Namespace.ID
    let onOpen: () -> Void
    let onOpenCut: (CardItem) -> Void
    let onChoose: (String) -> Void
    let onApply: () -> Void
    let onRemove: () -> Void

    /// What would come out: the user's choice among the options, else the
    /// verdict's own cut; nil when nothing would (an add, or no verdict).
    static func cut(for proposal: DeckProposal, chosen: String?) -> DeckCutOption? {
        if let chosen, let option = proposal.options.first(where: { $0.rowID == chosen }) { return option }
        if case .swap(let rowID, let out, let tag, let effect) = proposal.verdict {
            return proposal.options.first { $0.rowID == rowID } ?? DeckCutOption(rowID: rowID, card: out, tag: tag, effect: effect)
        }
        return nil
    }

    private var cut: DeckCutOption? { proposal.flatMap { Self.cut(for: $0, chosen: chosen) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    CardRowLead(item: card, zoom: zoom) {
                        if let reason = proposal?.reason {
                            ReasonDetailLine(reason: reason, price: card.price, owned: card.owned)
                        } else {
                            Text(card.typeLine ?? "")
                        }
                    }
                }
                .buttonStyle(.plain)
                // On the lead, not the card: an identifier on a container
                // is stamped on every element inside it.
                .accessibilityIdentifier("propose-row-\(card.name)")
                Button("Remove from picks", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 32)
                    .accessibilityIdentifier("propose-remove-\(card.name)")
            }
            Divider()
            verdict
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button("Remove", systemImage: "xmark", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder private var verdict: some View {
        switch proposal?.verdict {
        case nil:
            HStack(spacing: 8) {
                if judging { ProgressView().controlSize(.small) }
                Text(judging ? "Weighing it against the deck…" : "Waiting for the deck's analysis…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .alreadyInDeck?:
            note("checkmark.circle.fill", .green, "In the deck")
        case .outsideIdentity?:
            note("exclamationmark.triangle.fill", .orange, "Outside the commander's colour identity")
        case .add(let effect)?:
            note("plus.circle.fill", .green, "There is room for it: nothing has to come out")
            if let effect, !effect.isNeutral { EffectLine(effect: effect) }
            action("Add to Deck", prominent: true)
        case .swap?:
            if let cut {
                cutRow(cut, lead: "In place of")
                if let effect = cut.effect, !effect.isNeutral { EffectLine(effect: effect) }
                action("Swap", prominent: true)
            }
        case .notBetter(let weakest)?:
            let kind = proposal?.isLand == true ? "land" : "card"
            note("equal.circle.fill", .orange,
                 weakest.map { "Not clearly better than \($0.name), the weakest \(kind) in the deck" } ?? "Nothing in the deck it would clearly improve on")
            if let cut {
                // The user chose what leaves: their call, shown with its cost.
                cutRow(cut, lead: "Swap anyway for")
                if let effect = cut.effect, !effect.isNeutral { EffectLine(effect: effect) }
                action("Swap Anyway", prominent: false)
            } else if !locked, let options = proposal?.options, !options.isEmpty {
                Menu {
                    cutChoices(options)
                } label: {
                    Label("Swap Anyway…", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("propose-anyway-\(card.name)")
            }
        }
    }

    private func note(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }

    /// The card going out, with its reason; a menu of the alternatives
    /// when there are any.
    private func cutRow(_ cut: DeckCutOption, lead: String) -> some View {
        HStack(spacing: 10) {
            Button { onOpenCut(cut.card) } label: {
                CardArtThumb(artURL: cut.card.artCropURL, fallbackURL: cut.card.imageURL, width: 44, height: 32, cornerRadius: 6)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(lead)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(cut.card.name)
                    .font(.subheadline.weight(.medium))
                    .strikethrough(color: .secondary)
                    .lineLimit(1)
                ReasonLabel(reason: cut.tag)
            }
            Spacer(minLength: 4)
            if !locked, let options = proposal?.options, options.count > 1 {
                Menu {
                    cutChoices(options)
                } label: {
                    Label("Change", systemImage: "chevron.up.chevron.down")
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Choose another card to cut")
                .accessibilityIdentifier("propose-change-\(card.name)")
            }
        }
    }

    @ViewBuilder private func cutChoices(_ options: [DeckCutOption]) -> some View {
        Section("Cut instead") {
            ForEach(options) { option in
                Button {
                    onChoose(option.rowID)
                } label: {
                    Label(option.card.name, systemImage: option.rowID == cut?.rowID ? "checkmark" : option.tag.systemImage)
                    Text(option.tag.text)
                }
            }
        }
    }

    @ViewBuilder private func action(_ title: String, prominent: Bool) -> some View {
        if !locked {
            Group {
                if prominent {
                    Button(action: onApply) { Text(title).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action: onApply) { Text(title).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
            }
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("propose-apply-\(card.name)")
        }
    }
}
