//
//  NewDeckView.swift
//  magic-hat
//
//  Create a deck: name, format, and — for commander formats — the
//  commander, chosen from a pushed search of legal commanders. A deck
//  starts empty; cards come from its own search or an import.
//

import SwiftUI
import SwiftData

struct NewDeckView: View {
    let onCreated: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var format: DeckFormat = .commander
    @State private var commander: PrintingSelection?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Deck name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("newdeck-name")
                    Picker("Format", selection: $format) {
                        ForEach(DeckFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("newdeck-format")
                }
                if format.hasCommander {
                    Section {
                        NavigationLink {
                            CommanderPickerView(format: format) { commander = $0 }
                        } label: {
                            HStack(spacing: 12) {
                                if let commander {
                                    CardArtThumb(artURL: commander.artCropURL, fallbackURL: commander.imageURL)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(commander.name).foregroundStyle(.primary)
                                        Text("\(commander.setName) #\(commander.collectorNumber)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("Commander")
                                    Spacer()
                                    Text("Choose Later").foregroundStyle(.secondary)
                                }
                            }
                        }
                        if commander != nil {
                            Button("Remove Commander", role: .destructive) { commander = nil }
                        }
                    } footer: {
                        Text("Searching for cards in this deck will stay within the commander's colour identity.")
                    }
                }
            }
            .navigationTitle("New Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("newdeck-create")
                }
            }
            .alert("Couldn't Create Deck", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .onAppear { nameFocused = true }
        }
    }

    private func create() {
        do {
            let deck = try DeckEditController.createDeck(name: name, format: format, commander: commander, context: modelContext)
            dismiss()
            onCreated(deck.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Legal commanders for the format, by name, from Scryfall.
struct CommanderPickerView: View {
    let format: DeckFormat
    let onPick: (PrintingSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var controller = SearchController()
    @State private var text = ""

    var body: some View {
        Group {
            switch controller.phase {
            case .idle:
                ContentUnavailableView("Find a Commander", systemImage: "crown",
                                       description: Text("Type a name. Only cards that can be your commander are shown."))
            case .searching:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView.search(text: text)
            case .failed(let message):
                ContentUnavailableView("Search Failed", systemImage: "wifi.exclamationmark", description: Text(message))
            case .results:
                // The row's own button is the pick: a Button wrapped around
                // the row would sit *behind* it and never get the tap.
                List(controller.results) { item in
                    DeckSearchRow(item: item, ownedCopies: nil, inDeck: 0, showsAdd: false, onOpen: {
                        onPick(PrintingSelection(item: item))
                        dismiss()
                    })
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Commander")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Commander name")
        .onChange(of: text) { _, value in
            let t = value.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2 else { controller.clear(); return }
            // Scryfall's own `is:commander` covers legendary creatures and
            // the "can be your commander" planeswalkers; legality for the
            // format on top.
            controller.query.formats = format.legalityKey.flatMap(MagicFormat.init(rawValue:)).map { [$0] } ?? []
            controller.scheduleText("\(t) is:commander")
        }
    }
}
