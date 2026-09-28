//
//  DeckProposeView.swift
//  magic-hat
//
//  "What would I cut for these?" — the user searches and picks a few
//  cards, and each gets the planner's verdict as the picks change: swap
//  it in for a named card (with the deck re-scored), add it while the
//  list is short, or not clearly better than the weakest card in the list.
//  The same rules as the swap table (DeckPlan.propose), so the answers
//  agree with Suggested Swaps. A verdict's button makes the change through
//  the deck's DeckAddSession, like a swap row.
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
    @State private var picks: [CardItem] = []
    @State private var verdicts: [String: DeckProposal] = [:]
    @State private var isJudging = false
    @State private var applied = 0
    @State private var error: String?
    @State private var viewer: CardViewerSession?
    @Namespace private var zoom

    private var deckTracker: DeckChangeTracker { .shared }

    init(deckID: UUID, controller: DeckAnalysisController, context: ModelContext) {
        self.deckID = deckID
        self.controller = controller
        _session = State(initialValue: DeckAddSession(deckID: deckID, context: context))
    }

    var body: some View {
        NavigationStack {
            List {
                picksSection
                resultsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Try Cards")
            .navigationSubtitle(snapshot?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for cards to try")
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

    // MARK: Sections

    @ViewBuilder private var picksSection: some View {
        Section {
            if picks.isEmpty {
                Text("Search below and tap + on the cards you're thinking about. Each one gets a verdict: what it would replace, or why it wouldn't.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(picks) { card in
                ProposalRow(card: card, proposal: verdicts[card.id], judging: isJudging && verdicts[card.id] == nil,
                            locked: snapshot?.isLocked ?? true, zoom: zoom,
                            onOpen: { open(card, in: picks) },
                            onApply: { apply(card, verdicts[card.id]) },
                            onRemove: { withAnimation { picks.removeAll { $0.id == card.id } } })
            }
        } header: {
            HStack {
                Text(picks.isEmpty ? "Your Picks" : "Your Picks · \(picks.count)")
                Spacer()
                if isJudging { ProgressView().controlSize(.mini) }
            }
        } footer: {
            if !picks.isEmpty {
                Text("Judged like Suggested Swaps: the strongest pick takes the weakest card, a cut never leaves a role short, and no card is cut twice.")
            }
        }
    }

    @ViewBuilder private var resultsSection: some View {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            Section("Results") {
                switch search.phase {
                case .searching:
                    HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                default:
                    if search.results.isEmpty {
                        Text("No cards match.").foregroundStyle(.secondary)
                    }
                    ForEach(search.results.prefix(60)) { card in
                        let picked = picks.contains { $0.id == card.id }
                        HStack(spacing: 8) {
                            Button { open(card, in: Array(search.results.prefix(60))) } label: {
                                CardRowLead(item: card, zoom: zoom) {
                                    Text(card.typeLine ?? card.setName)
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                withAnimation {
                                    if picked { picks.removeAll { $0.id == card.id } } else { picks.append(card) }
                                }
                            } label: {
                                Image(systemName: picked ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.title2)
                                    .symbolRenderingMode(.hierarchical)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(picked ? "Remove \(card.name) from picks" : "Try \(card.name)")
                            .accessibilityIdentifier("propose-pick-\(card.name)")
                        }
                    }
                }
            }
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
    }

    private func open(_ card: CardItem, in cards: [CardItem]) {
        viewer = CardViewerSession(items: cards, currentID: card.id, deck: session)
    }

    private func apply(_ card: CardItem, _ proposal: DeckProposal?) {
        guard let proposal else { return }
        do {
            switch proposal.verdict {
            case .swap(let outRowID, _, _, _):
                if let outID = UUID(uuidString: outRowID) {
                    let current = snapshot?.playedItems.first { $0.id == outID }?.quantity ?? 1
                    try DeckEditController.setQuantity(deckCardID: outID, current - 1, context: modelContext)
                }
                try session.setQuantity(card, session.quantity(of: card) + 1)
            case .add, .notBetter:
                try session.setQuantity(card, session.quantity(of: card) + 1)
            case .alreadyInDeck, .outsideIdentity:
                return
            }
            applied += 1
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A pick and its verdict: the card, one line saying what the planner
/// makes of it, the deck's re-score, and the button that does it.
private struct ProposalRow: View {
    let card: CardItem
    let proposal: DeckProposal?
    let judging: Bool
    let locked: Bool
    let zoom: Namespace.ID
    let onOpen: () -> Void
    let onApply: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                if let label = actionLabel, !locked {
                    Button(label, action: onApply)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .accessibilityIdentifier("propose-apply-\(card.name)")
                }
            }
            verdictLine
                .font(.caption)
            if let effect, !effect.isNeutral {
                EffectLine(effect: effect)
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            Button("Remove", systemImage: "xmark", role: .destructive, action: onRemove)
        }
        .accessibilityIdentifier("propose-row-\(card.name)")
    }

    private var effect: DeckSwapEffect? {
        switch proposal?.verdict {
        case .swap(_, _, _, let effect)?: return effect
        case .add(let effect)?: return effect
        default: return nil
        }
    }

    private var actionLabel: String? {
        switch proposal?.verdict {
        case .swap?: return "Swap"
        case .add?: return "Add"
        default: return nil
        }
    }

    @ViewBuilder private var verdictLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch proposal?.verdict {
            case .swap(_, let out, let tag, _)?:
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                Text("for \(Text(out.name).strikethrough())").foregroundStyle(.secondary).lineLimit(1)
                ReasonLabel(reason: tag)
            case .add?:
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                Text("Add it — the deck is short of its size").foregroundStyle(.secondary)
            case .notBetter(let weakest)?:
                Image(systemName: "equal.circle").foregroundStyle(.orange)
                Text(weakest.map { "Not clearly better than \($0.name), the weakest card in the list" } ?? "Not clearly better than anything in the list")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .alreadyInDeck?:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Already in the deck").foregroundStyle(.secondary)
            case .outsideIdentity?:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Outside the commander's colour identity").foregroundStyle(.secondary)
            case nil:
                if judging { Text("Weighing it up…").foregroundStyle(.secondary) }
            }
        }
    }
}
