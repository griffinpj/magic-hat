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
            .overlay(alignment: .topTrailing) { optionsMenu }
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

    // Floating Liquid Glass "…" menu, overlaid top-right so it never
    // consumes the navigation title's space. Placed outside the toolbar to
    // avoid the first-tap lag SwiftUI toolbar menus exhibit.
    private var optionsMenu: some View {
        Menu {
            Button {
                showingFileImporter = true
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .padding(.trailing, 16)
        .padding(.top, 8)
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
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                guard let text else {
                    importError = "Couldn't read the file as text."
                    return
                }
                let rows = try CSVParser.parseManaBox(text)
                guard !rows.isEmpty else {
                    importError = "No card rows found in the file."
                    return
                }
                parsedRows = rows
                showingWizard = true
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

#Preview {
    CollectionView()
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
