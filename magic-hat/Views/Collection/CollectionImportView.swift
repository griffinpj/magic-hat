//
//  CollectionImportView.swift
//  magic-hat
//
//  Import straight into the list (or collection) on screen, from its "…"
//  menu: pasted text or a file. Whatever it is — a list typed or copied
//  from a deck site, a CSV from ManaBox, Moxfield, Archidekt, Deckbox,
//  Dragon Shield, TCGplayer, Delver Lens or a spreadsheet, an MTGO .dek —
//  CardListReader works out the shape from the text itself and the sheet
//  says what it found (the source, rows, copies, how many name their
//  printing) before anything is added. A ManaBox export goes through the
//  ManaBox importer (it keeps ManaBox's ids and dates); everything else
//  through CollectionImportController. Either way it lands as one History
//  action, and cards that couldn't be found are named, never dropped.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct CollectionImportView: View {
    /// Where the cards go. Nil from the Collections tab's Import…, where
    /// the sheet offers the collections and lists to choose from.
    let collectionName: String?
    let isList: Bool

    init(collectionName: String?, isList: Bool, fileText: String? = nil, fileName: String? = nil) {
        self.collectionName = collectionName
        self.isList = isList
        _fileText = State(initialValue: fileText)
        _fileName = State(initialValue: fileName)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Small table: the destinations to choose from.
    @Query(sort: \MTGCollection.name) private var collections: [MTGCollection]
    /// The destination chosen in the sheet, when none was given.
    @State private var chosenName = ""
    /// What is typed or pasted.
    @State private var text = ""
    /// A chosen file's text; shown as a summary, not in the editor (an
    /// export is thousands of lines).
    @State private var fileText: String?
    @State private var fileName: String?
    @State private var parsed = CardListFile()
    @State private var isReading = false
    @State private var choosingFile = false
    @State private var isImporting = false
    @State private var error: String?
    @State private var result: Result?
    /// Cards in the list whose name the destination already holds.
    @State private var alreadyHeld: Int?

    struct Result: Identifiable {
        let id = UUID()
        let copies: Int
        let unresolved: [String]
    }

    /// Where the import lands: the given collection, else the chosen one.
    private var destination: String { collectionName ?? chosenName }
    private var destinationIsList: Bool {
        collectionName == nil ? collections.first { $0.name == chosenName }?.kind == .list : isList
    }
    private var target: String { destinationIsList ? "list" : "collection" }
    private var source: String { fileText ?? text }

    /// Anything a file of cards might be: the reader goes by the text, so
    /// an export with an odd extension (.dek, .tsv, none) still opens.
    private static let fileTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .text, .utf8PlainText, .xml, .data]

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                if collectionName == nil {
                    Section {
                        Picker("Into", selection: $chosenName) {
                            ForEach(collections) { c in
                                Label(c.name, systemImage: c.kind.systemImage).tag(c.name)
                            }
                        }
                        .accessibilityIdentifier("collection-import-target")
                    } footer: {
                        Text("A ManaBox export goes through its own importer, from the same menu.")
                    }
                }
                Section {
                    summary
                } header: {
                    Text("To Import")
                } footer: {
                    if let unreadLine { Text(unreadLine) }
                }
                if fileText == nil { textSection }
                Section {
                    NavigationLink {
                        ImportFormatsView()
                    } label: {
                        Label("Supported Files and Lists", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("collection-import-formats")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(collectionName.map { "Import into \(CollectionScope.displayName($0))" } ?? "Import Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isImporting {
                        ProgressView()
                    } else {
                        Button("Import") { runImport() }
                            .disabled(parsed.isEmpty || destination.isEmpty)
                            .accessibilityIdentifier("collection-import-run")
                    }
                }
            }
            .interactiveDismissDisabled(isImporting)
            // Read once per change, off the main actor: a file is thousands
            // of rows, and typing in the editor changes the text per key.
            .onAppear {
                if collectionName == nil, chosenName.isEmpty {
                    chosenName = collections.first { $0.kind == .collection }?.name ?? collections.first?.name ?? ""
                }
            }
            .task(id: source) {
                let source = self.source
                isReading = true
                // Typing: a pause before a pasted list is read again per key.
                if fileText == nil { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { return }
                let read = await Task.detached(priority: .userInitiated) { CardListReader.read(source) }.value
                guard !Task.isCancelled else { return }
                parsed = read
                isReading = false
            }
            .task(id: "\(parsed.cards.count)|\(parsed.totalCopies)|\(destination)") { await refreshHeld() }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: Self.fileTypes) { outcome in
                if case .success(let url) = outcome { Task { await read(url) } }
                if case .failure(let e) = outcome { error = e.localizedDescription }
            }
            .alert("Couldn't Import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .alert("Imported", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil; dismiss() } }), presenting: result) { _ in
                Button("OK") { result = nil; dismiss() }
            } message: { r in
                if r.unresolved.isEmpty {
                    Text("\(r.copies.formatted()) cards added to this \(target).")
                } else {
                    Text("\(r.copies.formatted()) cards added. Not found: " + r.unresolved.prefix(8).joined(separator: ", ")
                         + (r.unresolved.count > 8 ? " and \(r.unresolved.count - 8) more." : "."))
                }
            }
        }
    }

    private var sourceSection: some View {
        Section {
            HStack(spacing: 12) {
                PasteButton(payloadType: String.self) { strings in
                    fileText = nil
                    fileName = nil
                    text = strings.joined(separator: "\n")
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("collection-import-paste")
                Button {
                    choosingFile = true
                } label: {
                    Label("Choose File", systemImage: "doc")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("collection-import-file")
            }
            .frame(maxWidth: .infinity)
        } footer: {
            Text("A list from any deck site or typed as “4 Lightning Bolt”, or a file exported by another app.")
        }
    }

    private var textSection: some View {
        Section("Text") {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("collection-import-text")
        }
    }

    /// "Couldn't read 2 lines: … · …"
    private var unreadLine: String? {
        guard !parsed.unparsed.isEmpty else { return nil }
        let count = parsed.unparsed.count == 1 ? "1 line" : "\(parsed.unparsed.count) lines"
        let sample = parsed.unparsed.prefix(3).joined(separator: " · ")
        return "Couldn't read \(count): \(sample)" + (parsed.unparsed.count > 3 ? " …" : "")
    }

    @ViewBuilder private var summary: some View {
        if parsed.isEmpty {
            if isReading, !source.isEmpty {
                HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) }
            } else if fileText != nil {
                Text("No cards found in \(fileName ?? "this file").").foregroundStyle(.secondary)
                Button("Use Text Instead", systemImage: "text.alignleft") { fileText = nil; fileName = nil }
            } else {
                Text("Paste, type or choose a list.").foregroundStyle(.secondary)
            }
        } else {
            if let fileName { LabeledContent("File", value: fileName) }
            LabeledContent("Format", value: parsed.label)
                .accessibilityIdentifier("collection-import-format")
            LabeledContent("Cards", value: parsed.totalCopies.formatted())
            LabeledContent(parsed.kind == .text ? "Lines" : "Rows", value: parsed.cards.count.formatted())
            if parsed.foilCopies > 0 { LabeledContent("Foil", value: parsed.foilCopies.formatted()) }
            if parsed.exactPrintings > 0, parsed.exactPrintings < parsed.cards.count {
                LabeledContent("Name their printing", value: parsed.exactPrintings.formatted())
            }
            if let alreadyHeld, !destination.isEmpty {
                LabeledContent("Already in this \(target)", value: alreadyHeld.formatted())
                    .accessibilityIdentifier("collection-import-held")
            }
            if fileText != nil {
                Button("Use Text Instead", systemImage: "text.alignleft") { fileText = nil; fileName = nil }
            }
        }
    }

    /// How many of the list's cards the destination already has by name:
    /// a matching printing merges into its row, any other adds one.
    private func refreshHeld() async {
        let cards = parsed.cards
        let name = destination
        guard !cards.isEmpty, !name.isEmpty else { alreadyHeld = nil; return }
        let names = (try? await CollectionStore.shared(for: modelContext.container).entryNames(collectionName: name)) ?? []
        let held = await Task.detached(priority: .userInitiated) {
            cards.filter { names.contains($0.name.lowercased()) }.count
        }.value
        guard !Task.isCancelled else { return }
        alreadyHeld = held
    }

    /// The file as text, whatever it is; the reader tells the shapes apart.
    private func read(_ url: URL) async {
        let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
        }.value
        guard let outcome else { error = "Couldn't read the file as text."; return }
        fileName = url.lastPathComponent
        fileText = outcome
    }

    private func runImport() {
        isImporting = true
        let container = modelContext.container
        let name = destination
        let file = parsed
        let source = self.source
        Task {
            defer { isImporting = false }
            do {
                if file.isManaBox {
                    let rows = try await Task.detached(priority: .userInitiated) { try CSVParser.parseManaBox(source) }.value
                    let binders = Set(rows.map(\.binderName))
                    _ = try await ImportController.apply(rows: rows, selectedBinders: binders, collectionName: name,
                                                         mode: .add, container: container, progress: { _ in })
                    CollectionChangeTracker.shared.bump()
                    result = Result(copies: rows.reduce(0) { $0 + $1.quantity }, unresolved: [])
                } else {
                    let outcome = try await CollectionImportController.importCards(
                        file.cards, into: name, container: container, remote: !UITestSeed.isSeededRun)
                    result = Result(copies: outcome.copies, unresolved: outcome.unresolved)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// What the import reads, with a sample of each: the page that answers
/// "will my file work?" before trying it.
struct ImportFormatsView: View {
    private struct Sample: Identifiable {
        let title: String
        let detail: String
        let text: String
        var id: String { title }
    }

    private static let lists: [Sample] = [
        Sample(title: "A typed or pasted list", detail: "One card a line. The count can lead, trail or be left out; the printing, foil (*F*) and etched (*E*) marks are optional.",
               text: "4 Lightning Bolt\n4x Counterspell\nSol Ring x2\n1 Mithril Coat (LTR) 245 *F*\n2 Brainstorm [STA]\nRhystic Study"),
        Sample(title: "Deck sites", detail: "Moxfield, Archidekt, TappedOut, MTGGoldfish, Arena and MTGO text exports, headers and tags included.",
               text: "// SIDEBOARD\n1x Rhystic Study (jmp) 169 [Draw]\nSB: 2 Pyroblast"),
    ]

    private static let files: [Sample] = [
        Sample(title: "ManaBox", detail: "Collection export (.csv). Every binder is merged into this one.",
               text: "Binder Name,Binder Type,Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,…"),
        Sample(title: "Moxfield", detail: "Collection export (.csv).",
               text: "\"Count\",\"Tradelist Count\",\"Name\",\"Edition\",\"Condition\",\"Language\",\"Foil\",…,\"Collector Number\",…,\"Purchase Price\""),
        Sample(title: "Archidekt", detail: "Collection export (.csv), any choice of columns as long as Name is one.",
               text: "Quantity,Name,Finish,Condition,Date Added,Language,Purchase Price,Tags,Edition Name,Edition Code,…,Scryfall ID,Collector Number"),
        Sample(title: "Deckbox", detail: "Inventory export (.csv).",
               text: "Count,Tradelist Count,Name,Edition,Edition Code,Card Number,Condition,Language,Foil,…,My Price"),
        Sample(title: "Dragon Shield", detail: "Card Manager export (.csv), with its “sep=,” first line.",
               text: "Folder Name,Quantity,Trade Quantity,Card Name,Set Code,Set Name,Card Number,Condition,Printing,Language,Price Bought,…"),
        Sample(title: "TCGplayer", detail: "The app's collection export (.csv).",
               text: "Quantity,Name,Simple Name,Set,Card Number,Set Code,Printing,Condition,Language,…"),
        Sample(title: "Delver Lens", detail: "CSV export, commas or semicolons.",
               text: "QuantityX;Name;Edition;Edition code;Collector's number;Foil;Condition;Language"),
        Sample(title: "Deckstats, MTGGoldfish, CardSphere, Card Kingdom", detail: "Their collection CSVs.",
               text: "amount,card_name,is_foil,…,set_code,collector_number,language,condition\nCard,Set ID,Set Name,Quantity,Foil,Variation\ntitle,edition,foil,quantity"),
        Sample(title: "Your own spreadsheet", detail: "CSV, semicolons or tabs. A header row with a Name column and any of: Quantity (Qty, Count), Set or Set Code, Collector Number, Foil (Finish), Condition, Language, Scryfall ID, Purchase Price. Or no header at all: a count and a name.",
               text: "Name\tQty\tSet\tFoil\nDark Ritual\t4\tSTA\tno\n\n4,Swords to Plowshares\n2x,Wrath of God"),
        Sample(title: "MTGO deck file", detail: ".dek, the XML Magic Online saves.",
               text: "<Cards CatID=\"36322\" Quantity=\"4\" Sideboard=\"false\" Name=\"Lightning Bolt\" />"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.lists) { row($0) }
            } header: {
                Text("Lists")
            }
            Section {
                ForEach(Self.files) { row($0) }
            } header: {
                Text("Files")
            } footer: {
                Text("A file is recognised by what is in it, not by its name. A row is matched by its Scryfall ID when it has one, then by set and collector number, then by name in the set it gives, then by name alone. Rows that can't be matched are listed after the import.")
            }
        }
        .navigationTitle("Supported Files and Lists")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ sample: Sample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sample.title).font(.body.weight(.medium))
            Text(sample.detail).font(.caption).foregroundStyle(.secondary)
            Text(sample.text)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.vertical, 2)
    }
}
