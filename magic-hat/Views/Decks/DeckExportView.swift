//
//  DeckExportView.swift
//  magic-hat
//
//  Export as a sheet with the choices that change the text, then the ways
//  out: share as text, share as a file, copy. The options are a Form —
//  the shape of every options sheet on iOS (Print, Export in Notes) — and
//  the preview under them updates as they change, so what will be shared
//  is never a surprise. The actions sit in the sheet's bottom bar.
//
//  Options offered are the ones the data can honour: format, grouping,
//  sort, printings, missing-only, boards. Language and tokens are not — the
//  list holds English names and no token rows — so they are not shown as
//  controls that would do nothing.
//

import SwiftUI
import UniformTypeIdentifiers

struct DeckExportView: View {
    let snapshot: DeckSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var options = DeckExportOptions()
    @State private var copied = 0

    /// The list as it will be shared, built off the main actor when the
    /// options change; a computed property rebuilt it on every render.
    @State private var text: String

    init(snapshot: DeckSnapshot) {
        self.snapshot = snapshot
        _text = State(initialValue: DeckListParser.export(snapshot, options: DeckExportOptions()))
    }
    private var isArena: Bool { options.format == .arena }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $options.format) {
                        ForEach(DeckExportOptions.Format.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("export-format")
                } footer: {
                    Text(isArena
                         ? "Commander, Deck and Sideboard headers, as MTG Arena imports."
                         : "The list every deck site reads, with // headers. Magic Hat imports it back.")
                }

                Section("Options") {
                    Picker("Group by", selection: $options.grouping) {
                        ForEach(DeckExportOptions.Grouping.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(isArena)
                    Picker("Sort by", selection: $options.ordering) {
                        ForEach(DeckExportOptions.Ordering.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Include printings", isOn: $options.includesPrintings)
                    Toggle("Only missing cards", isOn: $options.onlyMissing)
                        .accessibilityIdentifier("export-missing")
                }

                Section {
                    boardToggle(.main, "Mainboard", note: snapshot.format.hasCommander ? "with commander" : nil)
                    boardToggle(.side, "Sideboard")
                    boardToggle(.maybe, "Maybeboard")
                        .disabled(isArena)
                } header: {
                    Text("Boards")
                } footer: {
                    if isArena { Text("Arena has no maybeboard.") }
                }

                Section("Preview") {
                    if text.isEmpty {
                        Text("Nothing to export with these options.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("export-preview")
                    }
                }
            }
            .task(id: options) {
                let snapshot = self.snapshot, options = self.options
                let built = await Task.detached(priority: .userInitiated) { DeckListParser.export(snapshot, options: options) }.value
                guard !Task.isCancelled else { return }
                text = built
            }
            .navigationTitle("Export List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .accessibilityIdentifier("export-cancel")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    // Words, not glyphs: the bar shows a Label as its icon
                    // alone, and share / document / two documents did not
                    // say text vs file.
                    ShareLink(item: text, subject: Text(snapshot.name), preview: SharePreview(snapshot.name)) {
                        Text("Share Text")
                    }
                    .disabled(text.isEmpty)
                    .accessibilityIdentifier("export-share-text")
                    ShareLink(item: DeckExportFile(name: snapshot.name, text: text),
                              preview: SharePreview("\(snapshot.name).txt", image: Image(systemName: "doc.text"))) {
                        Text("Share File")
                    }
                    .disabled(text.isEmpty)
                    .accessibilityIdentifier("export-share-file")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Copy") {
                        UIPasteboard.general.string = text
                        copied += 1
                    }
                    .disabled(text.isEmpty)
                    .accessibilityIdentifier("export-copy")
                }
            }
            .sensoryFeedback(.success, trigger: copied)
        }
    }

    private func boardToggle(_ board: DeckBoard, _ title: String, note: String? = nil) -> some View {
        Toggle(isOn: Binding(
            get: { options.boards.contains(board) },
            set: { on in if on { options.boards.insert(board) } else { options.boards.remove(board) } }
        )) {
            HStack(spacing: 6) {
                Text(title)
                if let note {
                    Text(note).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("export-board-\(board.rawValue)")
    }
}

/// The list as a `.txt` file for the share sheet — written on demand, so
/// the sheet never leaves files behind for options nobody shared.
nonisolated struct DeckExportFile: Transferable {
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let safe = file.name.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).txt")
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
