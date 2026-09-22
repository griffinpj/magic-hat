//
//  DeckBuildSheet.swift
//  magic-hat
//
//  Building, as a short guided sheet: choose where cards may come from,
//  review exactly what will move and what is missing, confirm, see the
//  result. The plan is computed off-main by DeckBuilder and shown before
//  anything changes, so nothing moves that the user didn't see.
//

import SwiftUI
import SwiftData

struct DeckBuildSheet: View {
    let deckID: UUID
    let deckName: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var collections: [String] = []
    @State private var chosen: Set<String> = []
    @State private var includeSideboard = false
    @State private var plan: BuildPlan?
    @State private var result: BuildResult?
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    done(result)
                } else if let plan {
                    review(plan)
                } else {
                    sources
                }
            }
            .navigationTitle("Build \(deckName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if result == nil { Button("Cancel") { dismiss() }.disabled(isWorking) }
                }
            }
            .interactiveDismissDisabled(isWorking)
            .alert("Couldn't Build", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .task { await loadCollections() }
        }
    }

    // MARK: Step 1

    private var sources: some View {
        Form {
            Section {
                ForEach(collections, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { chosen.contains(name) },
                        set: { on in if on { chosen.insert(name) } else { chosen.remove(name) } }
                    ))
                }
                if collections.isEmpty {
                    Text("No collections yet.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Take cards from")
            } footer: {
                Text("Cards move out of these collections into the deck. Exact printings are preferred, then non-foils; foils stay in the binder unless nothing else fits.")
            }
            Section {
                Toggle("Include sideboard", isOn: $includeSideboard)
            }
            Section {
                Button {
                    Task { await makePlan() }
                } label: {
                    HStack {
                        Spacer()
                        if isWorking { ProgressView() } else { Text("Continue").font(.headline) }
                        Spacer()
                    }
                }
                .disabled(chosen.isEmpty || isWorking)
                .accessibilityIdentifier("build-continue")
            }
        }
    }

    // MARK: Step 2

    private func review(_ plan: BuildPlan) -> some View {
        List {
            Section {
                HStack(spacing: 12) {
                    summaryStat("Will move", plan.readyCopies, .green)
                    summaryStat("Missing", plan.missingCopies, plan.missingCopies == 0 ? .secondary : .red)
                }
                .padding(.vertical, 4)
                if plan.alreadyBuilt {
                    Text("Everything the deck lists is already in it.").foregroundStyle(.secondary)
                }
            }
            if !plan.readyEntries.isEmpty {
                Section("From your collection") {
                    ForEach(plan.readyEntries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.name)
                                Spacer()
                                Text("×\(entry.ready)").monospacedDigit().foregroundStyle(.secondary)
                            }
                            ForEach(entry.takes, id: \.self) { take in
                                Text("\(take.quantity) from \(take.fromCollection) · \(take.printingLabel)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !plan.missingEntries.isEmpty {
                Section {
                    ForEach(plan.missingEntries) { entry in
                        HStack {
                            Label(entry.name, systemImage: "xmark.circle")
                                .foregroundStyle(.red)
                            Spacer()
                            Text("×\(entry.missing)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Missing")
                } footer: {
                    Text("These stay marked as missing in the deck. Build again after adding them to your collection.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await build(plan) }
                } label: {
                    Label(plan.readyCopies > 0 ? "Move \(plan.readyCopies) Cards Into Deck" : "Nothing to Move",
                          systemImage: "hammer")
                        // Bottom bars show a Label's icon alone by default.
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(plan.readyCopies == 0 || isWorking)
                .accessibilityIdentifier("build-confirm")
            }
        }
    }

    private func summaryStat(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Step 3

    private func done(_ result: BuildResult) -> some View {
        ContentUnavailableView {
            Label("Deck Built", systemImage: "checkmark.circle.fill")
        } description: {
            Text(result.missingCopies == 0
                 ? "\(result.movedCopies) cards moved into the deck. Every card is in place."
                 : "\(result.movedCopies) cards moved into the deck. \(result.missingCopies) still missing.")
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("build-done")
        }
    }

    // MARK: Work

    private func loadCollections() async {
        let store = CollectionStore.shared(for: modelContext.container)
        if let names = try? await store.collectionNames(), !Task.isCancelled {
            collections = names
            chosen = Set(names)
        }
    }

    private func makePlan() async {
        isWorking = true
        defer { isWorking = false }
        do {
            plan = try await DeckBuilder.shared(for: modelContext.container)
                .plan(deckID: deckID, sourceCollections: Array(chosen).sorted(), includeSideboard: includeSideboard)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func build(_ plan: BuildPlan) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await DeckBuilder.shared(for: modelContext.container).build(plan)
            CollectionChangeTracker.shared.bump()
            DeckChangeTracker.shared.bump()
            result = outcome
        } catch {
            self.error = error.localizedDescription
        }
    }
}
