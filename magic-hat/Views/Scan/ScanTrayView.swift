//
//  ScanTrayView.swift
//  magic-hat
//
//  The scanned cards before they go anywhere, the ManaBox review step:
//  each card's printing (tap for every printing, grouped by set), Normal /
//  Foil / Etched, and how many — then one Add into the collection or list
//  it starts on (AddTarget's rules), as one History action.
//

import SwiftUI
import SwiftData

struct ScanTrayView: View {
    let session: ScanSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MTGCollection.name) private var collections: [MTGCollection]
    @AppStorage(AddTarget.lastKey) private var lastCollection = ""
    @State private var target = ""
    @State private var error: String?
    @State private var added = 0
    @State private var confirmClear = false
    @State private var viewer: CardViewerSession?
    @Namespace private var zoom

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.tray) { item in
                        TrayRow(item: item, zoom: zoom, onChange: session.update) {
                            viewer = CardViewerSession(items: session.tray.map(\.card), currentID: item.card.id)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { session.remove(session.tray[i].id) }
                    }
                } footer: {
                    Text("Check each card's printing and finish; swipe to take one out.")
                }
                Section {
                    NavigationLink {
                        CollectionPickerView(selected: $target)
                    } label: {
                        Label(target.isEmpty ? "Choose a collection" : target, systemImage: "tray.full")
                            .foregroundStyle(target.isEmpty ? .secondary : .primary)
                    }
                    .accessibilityIdentifier("scan-target")
                } header: {
                    Text("Add To")
                }
            }
            .navigationTitle("\(session.trayCopies) Scanned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("scan-tray-done") }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .disabled(session.tray.isEmpty)
                        .confirmationDialog("Clear \(session.trayCopies == 1 ? "1 Scanned Card" : "\(session.trayCopies) Scanned Cards")?",
                                            isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Clear All", role: .destructive) { session.clear(); dismiss() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("They haven't been added anywhere yet, so they'll need scanning again.")
                        }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(action: addAll) {
                        Label(target.isEmpty ? "Add" : "Add \(session.trayCopies) to \(target)", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(target.isEmpty || session.tray.isEmpty)
                    .accessibilityIdentifier("scan-add-all")
                }
            }
            .onAppear {
                if target.isEmpty {
                    target = AddTarget.resolve(browsing: nil, item: nil,
                                               last: lastCollection.isEmpty ? nil : lastCollection,
                                               existing: collections.map(\.name))
                }
            }
            .sensoryFeedback(.success, trigger: added)
            .fullScreenCover(item: $viewer) { v in
                CardViewerView(items: v.items, currentID: Bindable(v).currentID)
                    .navigationTransition(.zoom(sourceID: v.currentID ?? "", in: zoom))
            }
            .alert("Couldn't Add", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func addAll() {
        let target = self.target
        Task {
            do {
                try await session.addAll(to: target, context: modelContext)
                lastCollection = target
                added += 1
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct TrayRow: View {
    let item: ScanTrayItem
    let zoom: Namespace.ID
    let onChange: (ScanTrayItem) -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onOpen) {
                    CardRowLead(item: item.card, zoom: zoom) {
                        Text(PriceFormat.string(item.price))
                    }
                }
                .buttonStyle(.plain)
                Stepper(value: Binding(get: { item.quantity }, set: { var copy = item; copy.quantity = $0; onChange(copy) }), in: 0...99) {
                    Text("×\(item.quantity)").monospacedDigit().font(.headline)
                }
                .fixedSize()
                .accessibilityLabel("\(item.card.name), \(item.quantity) copies")
            }
            NavigationLink {
                PrintingPickerView(oracleID: item.card.oracleID, fallbackScryfallID: item.printing.scryfallID,
                                   selectedID: item.printing.scryfallID) { picked in
                    var copy = item
                    copy.printing = picked
                    copy.exactPrinting = true
                    copy.finishes = CardFinish.allCases
                    onChange(copy)
                }
            } label: {
                HStack(spacing: 6) {
                    SetSymbolView(setCode: item.printing.setCode, size: 16, tint: .primary, rarity: item.printing.rarity)
                    Text("\(item.printing.setName) #\(item.printing.collectorNumber)").lineLimit(1)
                    if !item.exactPrinting {
                        Text("check printing")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.subheadline)
            }
            HStack(spacing: 10) {
                Picker("Finish", selection: Binding(get: { item.finish }, set: { var copy = item; copy.finish = $0; onChange(copy) })) {
                    ForEach(item.finishes, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Menu {
                    Picker("Language", selection: Binding(get: { item.language }, set: { var copy = item; copy.language = $0; onChange(copy) })) {
                        ForEach(CardLanguage.codes, id: \.self) { Text(CardLanguage.name($0)).tag($0) }
                    }
                } label: {
                    Text(item.language.uppercased())
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.fill.tertiary, in: Capsule())
                }
                .accessibilityLabel("Language, \(CardLanguage.name(item.language))")
            }
        }
        .padding(.vertical, 4)
    }
}
