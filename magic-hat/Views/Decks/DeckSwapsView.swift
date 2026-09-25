//
//  DeckSwapsView.swift
//  magic-hat
//
//  The swap table: IN ← OUT with each side's reason and the deck re-scored
//  as if the swap were made; adds while the list is short, cuts while it
//  is over. Rules-based (DeckPlan), no model. Reached from the Cards tab's
//  banner row whenever there is something to suggest, from Stats, and
//  from the "…" menu. A swap does the add and takes one copy of the cut
//  in one tap through the same DeckAddSession the add sheet uses, so the
//  count on a row, the viewer's bar and the deck agree; tapping a row
//  opens the viewer with the zoom transition from its art.
//
//  Recommended cards are not here: they are a scope of the add sheet,
//  where adding belongs.
//

import SwiftUI
import SwiftData

struct DeckSwapsView: View {
    let deckID: UUID
    let controller: DeckAnalysisController

    @Environment(\.modelContext) private var modelContext
    @Namespace private var zoom
    @State private var session: DeckAddSession
    @State private var snapshot: DeckSnapshot?
    @State private var viewer: CardViewerSession?
    @State private var changes = 0
    @State private var error: String?

    private var deckTracker: DeckChangeTracker { .shared }
    private var collectionTracker: CollectionChangeTracker { .shared }

    init(deckID: UUID, controller: DeckAnalysisController, context: ModelContext) {
        self.deckID = deckID
        self.controller = controller
        _session = State(initialValue: DeckAddSession(deckID: deckID, context: context))
    }

    private var locked: Bool { snapshot?.isLocked ?? true }

    var body: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: viewer?.currentID) { old, id in
                    guard old != nil, let id else { return }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(id) }
                }
        }
        .navigationTitle("Swaps")
        .navigationSubtitle(snapshot?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewer) { v in
            CardViewerView(items: v.items, currentID: Bindable(v).currentID, deck: v.deck)
                .navigationTransition(.zoom(sourceID: v.currentID ?? "", in: zoom))
        }
        .sensoryFeedback(.success, trigger: changes)
        .alert("Couldn't Update Deck", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task(id: "\(deckTracker.revision)|\(collectionTracker.revision)") { await load() }
    }

    @ViewBuilder private var content: some View {
        if let plan = controller.plan {
            swaps(plan)
        } else if controller.isPlanning || controller.analysis == nil {
            // The plan reads every spare card in the collection; a second
            // or two on a big one, off the main actor. Say so.
            ProgressView("Reading the collection…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Nothing to Swap", systemImage: "arrow.left.arrow.right",
                                   description: Text("Add a few cards and a commander first."))
        }
    }

    @ViewBuilder private func swaps(_ plan: DeckPlan) -> some View {
        if plan.changeCount == 0 {
            ContentUnavailableView("Nothing to Swap", systemImage: "arrow.left.arrow.right",
                                   description: Text(plan.recommendations.isEmpty
                                                     ? "Nothing outside the list beats what is in it."
                                                     : "No candidate is clearly better than the weakest card in the list."))
        } else {
            List {
                if !plan.swaps.isEmpty {
                    Section {
                        ForEach(plan.swaps) { swap in
                            SwapRow(inCard: swap.inCard, inReason: swap.inReason, outCard: swap.outCard, outTag: swap.outTag,
                                    effect: swap.effect, inDeck: session.quantity(of: swap.inCard), locked: locked, zoom: zoom,
                                    onSwap: { apply(swap) }, onOpen: { open(swap.inCard, in: plan.swaps.map(\.inCard)) })
                                .id(swap.inCard.id)
                        }
                    } header: {
                        Text("Swaps")
                    } footer: {
                        Text("Weakest card out while the add is clearly better; a cut never opens a gap in the floors.")
                    }
                }
                if !plan.fills.isEmpty {
                    Section {
                        ForEach(plan.fills) { fill in
                            FillRow(card: fill.inCard, reason: fill.reason, effect: fill.effect,
                                    inDeck: session.quantity(of: fill.inCard), locked: locked, zoom: zoom,
                                    onSetQuantity: { setQuantity(fill.inCard, $0) }, onOpen: { open(fill.inCard, in: plan.fills.map(\.inCard)) })
                                .id(fill.inCard.id)
                        }
                    } header: {
                        Text("Add · \(plan.sizeAfter) of \(plan.targetSize)")
                    }
                }
                if !plan.trims.isEmpty {
                    Section {
                        ForEach(plan.trims) { trim in
                            TrimRow(card: trim.outCard, quantity: trim.quantity, reason: trim.tag, effect: trim.effect, locked: locked,
                                    onCut: { cut(trim) })
                        }
                    } header: {
                        Text("Cut")
                    }
                }
                Section {
                    if !plan.stillShort.isEmpty {
                        Text("Still short on " + DeckAnalysis.list(plan.stillShort.map { $0.label.lowercased() }) + " after these.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(controller.sourcesLine)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: Actions

    private func load() async {
        let store = DeckStore.shared(for: modelContext.container)
        if let fetched = try? await store.snapshot(deckID: deckID), !Task.isCancelled {
            snapshot = fetched
            session.update(from: fetched)
            controller.refresh(snapshot: fetched, container: modelContext.container)
        }
    }

    private func setQuantity(_ card: CardItem, _ quantity: Int) {
        do {
            try session.setQuantity(card, quantity)
            changes += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// IN goes on the mainboard, one copy of OUT comes off.
    private func apply(_ swap: DeckSwap) {
        guard let outID = UUID(uuidString: swap.outRowID) else { return }
        do {
            let current = snapshot?.playedItems.first { $0.id == outID }?.quantity ?? 1
            try DeckEditController.setQuantity(deckCardID: outID, current - 1, context: modelContext)
            try session.setQuantity(swap.inCard, session.quantity(of: swap.inCard) + 1)
            changes += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cut(_ trim: DeckTrim) {
        guard let outID = UUID(uuidString: trim.outRowID) else { return }
        do {
            let current = snapshot?.playedItems.first { $0.id == outID }?.quantity ?? trim.quantity
            try DeckEditController.setQuantity(deckCardID: outID, current - trim.quantity, context: modelContext)
            changes += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ card: CardItem, in items: [CardItem]) {
        session.board = .main
        viewer = CardViewerSession(items: items, currentID: card.id, deck: session)
    }
}

// MARK: - Rows

/// IN ← OUT, each with one reason, and what the deck would score after.
private struct SwapRow: View {
    let inCard: CardItem
    let inReason: CardReason
    let outCard: CardItem
    let outTag: CardReason
    let effect: DeckSwapEffect?
    let inDeck: Int
    let locked: Bool
    let zoom: Namespace.ID
    let onSwap: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    CardRowLead(item: inCard, zoom: zoom) {
                        ReasonDetailLine(reason: inReason, price: inCard.priceUSD, owned: inCard.owned)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("swap-row-\(inCard.name)")
                if !locked {
                    Button(inDeck > 0 ? "In" : "Swap", action: onSwap)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(inDeck > 0)
                        .accessibilityIdentifier("swap-apply-\(inCard.name)")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
                Text("for \(Text(outCard.name).strikethrough())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ReasonLabel(reason: outTag)
            }
            if let effect, !effect.isNeutral {
                EffectLine(effect: effect)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A card to add while the list is short: "+" (a stepper once it is in).
private struct FillRow: View {
    let card: CardItem
    let reason: CardReason
    let effect: DeckSwapEffect?
    let inDeck: Int
    let locked: Bool
    let zoom: Namespace.ID
    let onSetQuantity: (Int) -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    CardRowLead(item: card, zoom: zoom) {
                        ReasonDetailLine(reason: reason, price: card.priceUSD, owned: card.owned)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fill-row-\(card.name)")
                if !locked {
                    if inDeck == 0 {
                        Button {
                            onSetQuantity(1)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add \(card.name)")
                        .accessibilityIdentifier("fill-add-\(card.name)")
                    } else {
                        QuantityStepper(quantity: inDeck, name: card.name, idPrefix: "fill", onSet: onSetQuantity)
                    }
                }
            }
            if let effect, !effect.isNeutral { EffectLine(effect: effect) }
        }
        .padding(.vertical, 2)
    }
}

private struct TrimRow: View {
    let card: CardItem
    let quantity: Int
    let reason: CardReason
    let effect: DeckSwapEffect?
    let locked: Bool
    let onCut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CardRowLead(item: card) {
                    ReasonDetailLine(reason: reason, price: card.priceUSD, owned: false)
                }
                if !locked {
                    Button(quantity > 1 ? "Cut \(quantity)" : "Cut", action: onCut)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
            if let effect, !effect.isNeutral { EffectLine(effect: effect) }
        }
        .padding(.vertical, 2)
    }
}

/// "+0.3 power · −0.2 playability · breaks a combo".
private struct EffectLine: View {
    let effect: DeckSwapEffect

    var body: some View {
        HStack(spacing: 8) {
            delta("power", effect.power)
            delta("impact", effect.impact)
            delta("playability", effect.playability)
            if !effect.breaks.isEmpty { Text(effect.breaks.count == 1 ? "breaks a combo" : "breaks \(effect.breaks.count) combos").foregroundStyle(.red) }
            if !effect.gains.isEmpty { Text(effect.gains.count == 1 ? "gains a combo" : "gains \(effect.gains.count) combos").foregroundStyle(.green) }
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder private func delta(_ label: String, _ x: Double) -> some View {
        if x != 0 {
            Text((x > 0 ? "+" : "−") + String(format: "%.1f", abs(x)) + " " + label)
                .foregroundStyle(x > 0 ? Color.green : Color.orange)
                .monospacedDigit()
        }
    }
}

