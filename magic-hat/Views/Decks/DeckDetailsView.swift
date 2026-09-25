//
//  DeckDetailsView.swift
//  magic-hat
//
//  The Details tab: the deck's settings (name, format, commander, lock,
//  notes) and its life-cycle actions (build, disassemble, export, delete),
//  as a Form. Edits go straight to DeckEditController; the parent refetches
//  on the tracker.
//

import SwiftUI
import SwiftData

struct DeckDetailsView: View {
    let snapshot: DeckSnapshot
    let onBuild: () -> Void
    let onDisassemble: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var name: String
    @State private var notes: String
    @State private var notesTask: Task<Void, Never>?
    @State private var error: String?

    init(snapshot: DeckSnapshot, onBuild: @escaping () -> Void, onDisassemble: @escaping () -> Void,
         onExport: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onBuild = onBuild
        self.onDisassemble = onDisassemble
        self.onExport = onExport
        self.onDelete = onDelete
        _name = State(initialValue: snapshot.name)
        _notes = State(initialValue: snapshot.notes)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .submitLabel(.done)
                    .onSubmit(commitName)
                Picker("Format", selection: Binding(
                    get: { snapshot.format },
                    set: { format in attempt { try DeckEditController.setFormat(deckID: snapshot.id, format, context: modelContext) } }
                )) {
                    ForEach(DeckFormat.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Locked", isOn: Binding(
                    get: { snapshot.isLocked },
                    set: { locked in attempt { try DeckEditController.setLocked(deckID: snapshot.id, locked, context: modelContext) } }
                ))
                .accessibilityIdentifier("deck-lock")
            } footer: {
                Text("A locked deck can't be changed, and its search looks inside the deck instead of adding to it.")
            }

            if snapshot.format.hasCommander {
                Section("Commander") {
                    ForEach(snapshot.commanders) { commander in
                        HStack(spacing: 12) {
                            CardArtThumb(artURL: commander.card.artCropURL, fallbackURL: commander.card.imageURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commander.card.name)
                                HStack(spacing: 2) {
                                    ForEach(commander.card.colorIdentity, id: \.self) { color in
                                        ManaSymbolView(symbol: ManaSymbol(color.rawValue), size: 14)
                                    }
                                }
                            }
                        }
                    }
                    NavigationLink(snapshot.commanders.isEmpty ? "Choose Commander…" : "Change Commander…") {
                        CommanderPickerView(format: snapshot.format) { printing in
                            attempt { try DeckEditController.setCommander(deckID: snapshot.id, printing, context: modelContext) }
                        }
                    }
                    .disabled(snapshot.isLocked)
                }
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 100)
                    .onChange(of: notes) { _, value in scheduleNotes(value) }
            }

            Section("About") {
                LabeledContent("Cards", value: "\(snapshot.mainCopies)")
                LabeledContent("Value", value: PriceFormat.compact(snapshot.stats.totalValue))
                LabeledContent("Built", value: snapshot.isBuilt ? "\(snapshot.builtCopies) of \(snapshot.mainCopies) cards" : "Not built")
                LabeledContent("Created", value: snapshot.createdDate.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Updated", value: snapshot.updatedDate.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Button("Build from Collection…", systemImage: "hammer", action: onBuild)
                    .disabled(snapshot.mainCopies == 0)
                    .accessibilityIdentifier("deck-build")
                Button("Disassemble…", systemImage: "arrow.uturn.backward", action: onDisassemble)
                    .disabled(!snapshot.isBuilt)
                Button("Export List…", systemImage: "square.and.arrow.up", action: onExport)
                    .accessibilityIdentifier("deck-export")
            } footer: {
                Text("Building moves cards out of your collection into this deck; disassembling moves them back. Nothing is ever duplicated, and every move is in History.")
            }

            Section {
                Button("Delete Deck", systemImage: "trash", role: .destructive, action: onDelete)
                    .frame(maxWidth: .infinity)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .alert("Couldn't Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .onChange(of: snapshot.name) { _, value in name = value }
    }

    private func commitName() {
        guard name != snapshot.name else { return }
        attempt { try DeckEditController.rename(deckID: snapshot.id, to: name, context: modelContext) }
    }

    private func scheduleNotes(_ value: String) {
        notesTask?.cancel()
        notesTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, value != snapshot.notes else { return }
            attempt { try DeckEditController.setNotes(deckID: snapshot.id, value, context: modelContext) }
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { self.error = error.localizedDescription }
    }
}
