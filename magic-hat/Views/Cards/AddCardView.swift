//
//  AddCardView.swift
//  magic-hat
//
//  The Add sheet: pick a printing and a collection, set quantity / finish /
//  language / condition / price, add. Below the form, every copy of this
//  card already in any collection, each editable (tap) or removable (swipe,
//  or trash). Stays open after adding so several printings can go in.
//
//  Structure follows the platform rather than the reference app: one sheet
//  holding a NavigationStack + Form; pickers are pushed, searchable screens;
//  destructive actions confirm through confirmationDialog.
//

import SwiftUI
import SwiftData

struct AddCardView: View {
    let item: CardItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var printing: PrintingSelection
    @State private var form: EntryFormState
    @State private var collectionName: String
    @State private var owned: [CardItem] = []
    @State private var addCount = 0
    @State private var errorMessage: String?
    @State private var editing: CardItem?
    @State private var pendingDelete: CardItem?

    private var store: CollectionStore { .shared(for: modelContext.container) }

    init(item: CardItem) {
        self.item = item
        let selection = PrintingSelection(item: item)
        _printing = State(initialValue: selection)
        _form = State(initialValue: EntryFormState(
            finish: item.finish,
            condition: CardCondition(rawValue: item.condition)?.rawValue ?? CardCondition.nearMint.rawValue,
            language: item.language.isEmpty ? "en" : item.language,
            price: selection.marketPrice(for: item.finish)
        ))
        _collectionName = State(initialValue: item.owned ? item.collectionName : "")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var totalOwned: Int { owned.reduce(0) { $0 + $1.quantity } }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                printingSection
                EntryFormSections(form: $form, printing: printing)
                collectionSection
                ownedSection
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("add-card-done")
                }
                // The primary action lives in the bottom bar: always on
                // screen regardless of how long the form is, and the sheet
                // stays open so several printings can be added in a row.
                ToolbarItem(placement: .bottomBar) {
                    Button(action: add) {
                        Label(collectionName.isEmpty ? "Add" : "Add to \(collectionName)", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(collectionName.isEmpty)
                    .accessibilityIdentifier("add-card-confirm")
                }
            }
            .alert("Couldn't add", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $editing) { row in
                EditEntryView(item: row)
            }
            .confirmationDialog(
                "Remove \(pendingDelete?.name ?? "")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { row in
                Button("Remove \(row.quantity) from \(row.collectionName)", role: .destructive) { remove(row) }
                Button("Cancel", role: .cancel) {}
            } message: { row in
                Text("\(row.setName) #\(row.collectorNumber) · \(row.finish.displayName). Recorded in History.")
            }
            .task(id: CollectionChangeTracker.shared.revision) { await loadOwned() }
            .sensoryFeedback(.success, trigger: addCount)
        }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                CardImageView(urlString: printing.imageURL, aspectRatio: printing.aspectRatio,
                              cornerRadius: 8, targetWidth: 110)
                    .frame(width: 84)
                VStack(alignment: .leading, spacing: 6) {
                    Text(printing.name).font(.headline)
                    HStack(spacing: 4) {
                        SetSymbolView(setCode: printing.setCode, size: 14, tint: .secondary, rarity: printing.rarity)
                        Text("\(printing.setName) #\(printing.collectorNumber)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Label("\(totalOwned) owned", systemImage: "tray.full")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let market = printing.marketPrice(for: form.finish) {
                        Text("Market \(PriceFormat.string(market))")
                            .font(.caption.weight(.medium))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private var printingSection: some View {
        Section("Printing") {
            NavigationLink {
                PrintingPickerView(
                    oracleID: item.oracleID,
                    fallbackScryfallID: item.scryfallID,
                    selectedID: printing.scryfallID
                ) { picked in
                    printing = picked
                }
            } label: {
                HStack(spacing: 8) {
                    SetSymbolView(setCode: printing.setCode, size: 18, tint: .primary, rarity: printing.rarity)
                    Text(printing.setName)
                    Spacer()
                    Text("#\(printing.collectorNumber)")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("pick-printing")
        }
    }

    private var collectionSection: some View {
        Section("Collection") {
            NavigationLink {
                CollectionPickerView(selected: $collectionName)
            } label: {
                Label(collectionName.isEmpty ? "Choose a collection" : collectionName,
                      systemImage: "tray.full")
                    .foregroundStyle(collectionName.isEmpty ? .secondary : .primary)
            }
            .accessibilityIdentifier("pick-collection")
        }
    }

    private var ownedSection: some View {
        Section {
            if owned.isEmpty {
                Text("Not in any collection yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(owned) { row in
                    OwnedPrintingRow(item: row)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = row }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingDelete = row } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            Button { editing = row } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            }
        } header: {
            Text("In your collections")
        } footer: {
            if !owned.isEmpty { Text("Tap a row to edit it, swipe to remove.") }
        }
    }

    // MARK: Actions

    private func add() {
        do {
            try CollectionEditController.add(
                .init(
                    printing: printing,
                    collectionName: collectionName,
                    quantity: form.quantity,
                    finish: form.finish,
                    condition: form.condition,
                    language: form.language,
                    purchasePrice: form.price
                ),
                context: modelContext
            )
            addCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ row: CardItem) {
        guard let id = UUID(uuidString: row.id) else { return }
        do { try CollectionEditController.remove(entryID: id, context: modelContext) }
        catch { errorMessage = error.localizedDescription }
    }

    /// Every copy of this card (any printing) we own, in any collection.
    private func loadOwned() async {
        var ids = Set([item.scryfallID, printing.scryfallID])
        if let oracle = item.oracleID, let known = try? await store.printingIDs(oracleID: oracle) {
            ids.formUnion(known)
        }
        if let rows = try? await store.ownedItems(scryfallIDs: Array(ids)), !Task.isCancelled {
            owned = rows
        }
    }
}

// MARK: - Owned row

struct OwnedPrintingRow: View {
    let item: CardItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio,
                          cornerRadius: 6, targetWidth: 70)
                .frame(width: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    SetSymbolView(setCode: item.setCode, size: 14, tint: .primary, rarity: item.rarity)
                    Text(item.setName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("#\(item.collectorNumber)").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(PriceFormat.string(item.marketPrice)).font(.subheadline.weight(.medium)).monospacedDigit()
                    if let change = item.gainLoss {
                        Text(PriceFormat.change(change.amount, change.percent))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(change.amount >= 0 ? .green : .red)
                    }
                }
                HStack(spacing: 6) {
                    chip(item.collectionName, icon: "tray.full")
                    chip(item.language.uppercased())
                    chip(CardCondition.shortLabel(for: item.condition))
                    if item.finish != .normal { chip(item.finish.displayName.uppercased()) }
                }
                if let added = item.addedDate {
                    Text("Added \(added.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                Text("×\(item.quantity)")
                    .font(.headline)
                    .monospacedDigit()
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func chip(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9)) }
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

// MARK: - Edit sheet

/// Edit one owned row: the same fields as Add, prefilled, plus Remove.
struct EditEntryView: View {
    let item: CardItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var form: EntryFormState
    @State private var errorMessage: String?
    @State private var confirmingRemove = false

    private let printing: PrintingSelection

    init(item: CardItem) {
        self.item = item
        printing = PrintingSelection(item: item)
        _form = State(initialValue: EntryFormState(
            quantity: item.quantity,
            finish: item.finish,
            condition: CardCondition(rawValue: item.condition)?.rawValue ?? CardCondition.nearMint.rawValue,
            language: item.language.isEmpty ? "en" : item.language,
            price: item.purchasePrice ?? PrintingSelection(item: item).marketPrice(for: item.finish),
            priceEdited: item.purchasePrice != nil
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio,
                                      cornerRadius: 8, targetWidth: 110)
                            .frame(width: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.headline)
                            HStack(spacing: 4) {
                                SetSymbolView(setCode: item.setCode, size: 14, tint: .secondary, rarity: item.rarity)
                                Text("\(item.setName) #\(item.collectorNumber)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Label(item.collectionName, systemImage: "tray.full")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                EntryFormSections(form: $form, printing: printing)
                Section {
                    Button("Remove from \(item.collectionName)", role: .destructive) {
                        confirmingRemove = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.accessibilityIdentifier("edit-save")
                }
            }
            .confirmationDialog("Remove \(item.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove \(item.quantity)", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil },
                                                        set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        guard let id = UUID(uuidString: item.id) else { return }
        do {
            try CollectionEditController.update(
                entryID: id,
                edits: .init(quantity: form.quantity, finish: form.finish, condition: form.condition,
                             language: form.language, purchasePrice: form.price),
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() {
        guard let id = UUID(uuidString: item.id) else { return }
        do {
            try CollectionEditController.remove(entryID: id, context: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
