//
//  CollectionImportView.swift
//  magic-hat
//
//  Import straight into the list (or collection) on screen, from its "…"
//  menu: pasted text or a file. Text is any deck-list shape the deck import
//  reads — "4 Lightning Bolt", "1 Sol Ring (C21) 263 *F*", Arena, MTGO —
//  resolved against the catalog and then Scryfall; a ManaBox CSV imports
//  its rows as they are (printing, finish, condition, language, price),
//  every binder, merged into this one. Either way it lands as one History
//  action, and cards that couldn't be found are named, never dropped.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct CollectionImportView: View {
    let collectionName: String
    let isList: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var text = ""
    @State private var list = DeckList()
    @State private var csvRows: [ManaBoxRow]?
    @State private var fileName: String?
    @State private var choosingFile = false
    @State private var isImporting = false
    @State private var progress: Double?
    @State private var error: String?
    @State private var result: Result?

    struct Result: Identifiable {
        let id = UUID()
        let copies: Int
        let unresolved: [String]
    }

    private var target: String { isList ? "list" : "collection" }
    private var canImport: Bool { !(csvRows?.isEmpty ?? true) || !list.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        PasteButton(payloadType: String.self) { strings in
                            text = strings.joined(separator: "\n")
                            csvRows = nil
                            fileName = nil
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
                    Text("A list copied from any deck site or typed as “4 Lightning Bolt”, a .txt list, or a ManaBox .csv export.")
                }

                Section {
                    summary
                } header: {
                    Text("To Import")
                } footer: {
                    if csvRows == nil, !list.unparsed.isEmpty {
                        Text("Couldn't read: " + list.unparsed.prefix(3).joined(separator: " · ") + (list.unparsed.count > 3 ? " …" : ""))
                    }
                }

                if csvRows == nil {
                    Section("Text") {
                        TextEditor(text: $text)
                            .font(.body.monospaced())
                            .frame(minHeight: 180)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("collection-import-text")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Import into \(CollectionScope.displayName(collectionName))")
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
                            .disabled(!canImport)
                            .accessibilityIdentifier("collection-import-run")
                    }
                }
            }
            .interactiveDismissDisabled(isImporting)
            .task(id: text) {
                let text = self.text
                let parsed = await Task.detached(priority: .userInitiated) { DeckListParser.parse(text) }.value
                guard !Task.isCancelled else { return }
                list = parsed
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .utf8PlainText]) { outcome in
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

    @ViewBuilder private var summary: some View {
        if let csvRows {
            LabeledContent("File", value: fileName ?? "ManaBox export")
            LabeledContent("Rows", value: csvRows.count.formatted())
            LabeledContent("Cards", value: csvRows.reduce(0) { $0 + $1.quantity }.formatted())
            Button("Use Text Instead", role: .destructive) { self.csvRows = nil; fileName = nil }
        } else if list.isEmpty {
            Text("Paste, type or choose a list.").foregroundStyle(.secondary)
        } else {
            LabeledContent("Cards", value: list.totalCopies.formatted())
            LabeledContent("Lines", value: list.lines.count.formatted())
            if list.lines.contains(where: \.isFoil) {
                LabeledContent("Foil", value: list.lines.filter(\.isFoil).reduce(0) { $0 + $1.quantity }.formatted())
            }
        }
    }

    /// A ManaBox CSV is rows; anything else is list text.
    private func read(_ url: URL) async {
        let outcome = await Task.detached(priority: .userInitiated) { () -> (rows: [ManaBoxRow]?, text: String?, error: String?) in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return (nil, nil, "Couldn't read the file as text.")
            }
            let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
            if firstLine.contains("Scryfall ID"), firstLine.contains("Quantity") {
                do { return (try CSVParser.parseManaBox(text), nil, nil) } catch { return (nil, nil, error.localizedDescription) }
            }
            return (nil, text, nil)
        }.value
        if let message = outcome.error { error = message; return }
        fileName = url.lastPathComponent
        if let rows = outcome.rows {
            csvRows = rows
        } else if let fileText = outcome.text {
            csvRows = nil
            text = fileText
        }
    }

    private func runImport() {
        isImporting = true
        let container = modelContext.container
        let name = collectionName
        Task {
            defer { isImporting = false }
            do {
                if let rows = csvRows {
                    let binders = Set(rows.map(\.binderName))
                    _ = try await ImportController.apply(rows: rows, selectedBinders: binders, collectionName: name,
                                                         mode: .add, container: container, progress: { _ in })
                    CollectionChangeTracker.shared.bump()
                    result = Result(copies: rows.reduce(0) { $0 + $1.quantity }, unresolved: [])
                } else {
                    result = try await Self.importText(list, into: name, container: container)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Resolves the list (the catalog first, Scryfall for the rest) and
    /// adds every line as one action.
    static func importText(_ list: DeckList, into collection: String, container: ModelContainer) async throws -> Result {
        let resolved = try await DeckImportController.resolve(list.lines, container: container)
        let context = container.mainContext
        let ids = Array(Set(resolved.compactMap(\.scryfallID)))
        var metas: [String: CardMeta] = [:]
        for chunk in ids.chunked(into: 500) {
            for meta in try context.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { chunk.contains($0.scryfallID) })) {
                metas[meta.scryfallID] = meta
            }
        }
        var requests: [CollectionEditController.AddRequest] = []
        var unresolved: [String] = []
        for line in resolved {
            guard let id = line.scryfallID, let meta = metas[id] else { unresolved.append(line.line.name); continue }
            let printing = PrintingSelection(item: CardItem(meta: meta, owned: false))
            let finish: CardFinish = line.line.isFoil ? .foil : .normal
            requests.append(.init(printing: printing, collectionName: collection, quantity: line.line.quantity, finish: finish,
                                  condition: CardCondition.nearMint.rawValue, language: AppSettings.cardLanguage,
                                  purchasePrice: printing.marketPrice(for: finish)))
        }
        if !requests.isEmpty { try await CollectionEditController.addMany(requests, context: context) }
        return Result(copies: requests.reduce(0) { $0 + $1.quantity }, unresolved: unresolved)
    }
}
