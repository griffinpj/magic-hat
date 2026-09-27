//
//  DeckImportView.swift
//  magic-hat
//
//  Import a list: the text (from a file, or pasted here with the system
//  PasteButton — no "Allow Paste" prompt that way), a live summary of what
//  it parses to, a name and a format, then Import.
//  Cards the catalog doesn't know are looked up on Scryfall; whatever still
//  can't be found is listed so nothing silently disappears.
//

import SwiftUI
import SwiftData

struct DeckImportView: View {
    let source: DeckImportSource
    let onImported: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var name: String
    @State private var format: DeckFormat
    @State private var isImporting = false
    @State private var error: String?
    @State private var outcome: DeckImportController.Outcome?
    /// A link to a deck on a deck site, fetched into `text`.
    @State private var link = ""
    @State private var isFetching = false
    @State private var fetchedFrom: String?
    @FocusState private var linkFocused: Bool

    init(source: DeckImportSource, onImported: @escaping (UUID) -> Void) {
        self.source = source
        self.onImported = onImported
        let list = DeckListParser.parse(source.text)
        _text = State(initialValue: source.text)
        _list = State(initialValue: list)
        _parsedText = State(initialValue: source.text)
        _name = State(initialValue: source.suggestedName ?? list.title ?? "")
        _format = State(initialValue: list.suggestedFormat)
    }

    /// The text as parsed, kept up to date off the main actor as the text
    /// changes. A computed property re-parsed the whole list on every
    /// render — every keystroke in the name field.
    @State private var list: DeckList
    @State private var parsedText: String

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                Section {
                    TextField("Deck name", text: $name)
                        .submitLabel(.done)
                        .accessibilityIdentifier("import-name")
                    Picker("Format", selection: $format) {
                        ForEach(DeckFormat.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    summary
                } header: {
                    Text("List")
                } footer: {
                    if !list.unparsed.isEmpty {
                        Text("Couldn't read: " + list.unparsed.prefix(3).joined(separator: " · ") + (list.unparsed.count > 3 ? " …" : ""))
                    }
                }
                Section {
                    if text.isEmpty {
                        PasteButton(payloadType: String.self) { strings in
                            text = strings.joined(separator: "\n")
                            let pasted = DeckListParser.parse(text)
                            if name.isEmpty, let title = pasted.title { name = title }
                            format = pasted.suggestedFormat
                        }
                        .buttonBorderShape(.capsule)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("import-paste")
                    }
                    TextEditor(text: $text)
                        // A link pasted where the list goes is fetched.
                        .onChange(of: text) { _, value in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.contains("\n"), DeckSite.recognise(trimmed) != nil, link.isEmpty {
                                link = trimmed
                                text = ""
                                fetchLink()
                            }
                        }
                        .font(.body.monospaced())
                        .frame(minHeight: 200)
                        .accessibilityIdentifier("import-text")
                } header: {
                    Text("Text")
                } footer: {
                    if text.isEmpty { Text("Or paste a list copied from Moxfield, Archidekt, MTGO, Arena or any deck site.") }
                }
            }
            // Re-parsed off the main actor as the text changes (the first
            // parse came with the init).
            .task(id: text) {
                let text = self.text
                guard text != parsedText else { return }
                let parsed = await Task.detached(priority: .userInitiated) { DeckListParser.parse(text) }.value
                guard !Task.isCancelled else { return }
                list = parsed
                parsedText = text
            }
            .onAppear { if source.focusesLink { linkFocused = true } }
            .navigationTitle("Import Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isImporting) }
                ToolbarItem(placement: .confirmationAction) {
                    if isImporting {
                        ProgressView()
                    } else {
                        Button("Import") { runImport() }
                            .disabled(list.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("import-run")
                    }
                }
            }
            .interactiveDismissDisabled(isImporting)
            .alert("Couldn't Import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .alert("Some Cards Not Found", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { finish() } }),
                   presenting: outcome) { _ in
                Button("OK") { finish() }
            } message: { outcome in
                Text("\(outcome.importedCopies) cards imported. Not found: " +
                     outcome.unresolved.prefix(8).map(\.name).joined(separator: ", ") +
                     (outcome.unresolved.count > 8 ? " and \(outcome.unresolved.count - 8) more." : "."))
            }
        }
    }

    /// Archidekt, Moxfield, MTGGoldfish or any raw text list, by link.
    private var linkSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("https://archidekt.com/decks/…", text: $link)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($linkFocused)
                    .onSubmit(fetchLink)
                    .accessibilityIdentifier("import-link")
                if isFetching {
                    ProgressView()
                } else if !link.isEmpty {
                    Button("Get", action: fetchLink)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("import-link-fetch")
                }
            }
            if link.isEmpty {
                PasteButton(payloadType: URL.self) { urls in
                    guard let url = urls.first else { return }
                    link = url.absoluteString
                    fetchLink()
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("import-link-paste")
            }
        } header: {
            Text("From a Link")
        } footer: {
            if let fetchedFrom {
                Text("Read from \(fetchedFrom). Check it below, then Import.")
            } else {
                Text("Archidekt, Moxfield or MTGGoldfish deck links, or a link to a text list.")
            }
        }
    }

    private func fetchLink() {
        let raw = link
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty, !isFetching else { return }
        isFetching = true
        linkFocused = false
        Task {
            defer { isFetching = false }
            do {
                let fetched = try await DeckSiteClient.shared.fetch(raw)
                text = fetched.text
                let parsed = DeckListParser.parse(fetched.text)
                if name.trimmingCharacters(in: .whitespaces).isEmpty { name = fetched.name ?? parsed.title ?? "" }
                format = fetched.format ?? parsed.suggestedFormat
                fetchedFrom = DeckSite.recognise(raw)?.label
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var summary: some View {
        let l = list
        if l.isEmpty {
            Text("Paste or type a deck list below.").foregroundStyle(.secondary)
        } else {
            LabeledContent("Cards", value: "\(l.totalCopies)")
            if let commander = l.lines(in: .commander).first {
                LabeledContent("Commander", value: commander.name)
            }
            LabeledContent("Mainboard", value: "\(l.copies(in: .main))")
            if l.copies(in: .side) > 0 { LabeledContent("Sideboard", value: "\(l.copies(in: .side))") }
            if l.copies(in: .maybe) > 0 { LabeledContent("Maybeboard", value: "\(l.copies(in: .maybe))") }
        }
    }

    private func runImport() {
        isImporting = true
        let container = modelContext.container
        let text = text, name = name, format = format
        Task {
            do {
                let result = try await DeckImportController.importDeck(text: text, name: name, format: format, container: container)
                isImporting = false
                if result.unresolved.isEmpty {
                    dismiss()
                    onImported(result.deckID)
                } else {
                    outcome = result
                }
            } catch {
                isImporting = false
                self.error = error.localizedDescription
            }
        }
    }

    private func finish() {
        guard let outcome else { return }
        self.outcome = nil
        dismiss()
        onImported(outcome.deckID)
    }
}
