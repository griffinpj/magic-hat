//
//  CollectionView.swift
//  magic-hat
//
//  Collection tab landing screen: lists the binders in the collection and
//  hosts the "…" menu whose Import action picks a ManaBox CSV. The file is
//  parsed here, then the wizard sheet opens with the parsed rows — no
//  file picker is presented from inside the sheet (which is fragile).
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Aggregated view of one binder for the list.
private struct BinderSummary: Identifiable {
    let name: String
    let uniqueCards: Int
    let totalCopies: Int
    var id: String { name }
}

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CollectionEntry.binderName) private var entries: [CollectionEntry]

    @State private var showingFileImporter = false
    @State private var parsedRows: [ManaBoxRow] = []
    @State private var showingWizard = false
    @State private var importError: String?
    @State private var isParsing = false

    private var errorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private var binders: [BinderSummary] {
        let grouped = Dictionary(grouping: entries, by: \.binderName)
        return grouped.map { name, rows in
            BinderSummary(
                name: name,
                uniqueCards: rows.count,
                totalCopies: rows.reduce(0) { $0 + $1.quantity }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if binders.isEmpty {
                    ContentUnavailableView {
                        Text("📭")
                            .font(.system(size: 64))
                    } description: {
                        Text("No binders yet.\nImport a collection from the “…” menu.")
                    }
                } else {
                    binderList
                }
            }
            .navigationTitle("Collection")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .overlay { if isParsing { parsingOverlay } }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                allowsMultipleSelection: false
            ) { result in
                handleFile(result)
            }
            .sheet(isPresented: $showingWizard) {
                ImportWizardView(rows: parsedRows)
            }
            .alert("Import Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // Brief spinner shown while the picked CSV is read + parsed off-main.
    private var parsingOverlay: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading file…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var binderList: some View {
        List(binders) { binder in
            NavigationLink {
                BinderDetailView(binderName: binder.name)
            } label: {
                HStack {
                    Image(systemName: "books.vertical.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(binder.name)
                            .font(.body.weight(.medium))
                        Text("\(binder.uniqueCards) cards · \(binder.totalCopies) copies")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isParsing = true
            Task {
                let outcome = await Self.parse(url: url)
                isParsing = false
                switch outcome {
                case .rows(let rows):
                    parsedRows = rows
                    showingWizard = true
                case .failure(let message):
                    importError = message
                }
            }
        }
    }

    private enum ParseOutcome: Sendable {
        case rows([ManaBoxRow])
        case failure(String)
    }

    /// Reads and parses the CSV off the main thread so picking a large file
    /// never stalls the UI. Returns rows or a user-facing error message.
    private static func parse(url: URL) async -> ParseOutcome {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
                    return .failure("Couldn't read the file as text.")
                }
                let rows = try CSVParser.parseManaBox(text)
                guard !rows.isEmpty else {
                    return .failure("No card rows found in the file.")
                }
                return .rows(rows)
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }
}

#Preview {
    CollectionView()
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
