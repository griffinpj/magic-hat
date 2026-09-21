//
//  MainTabView.swift
//  magic-hat
//
//  Root tab scaffold. Uses the modern `Tab` API so the app picks up the
//  native Liquid Glass tab bar on iOS 26, with Search in the dedicated
//  search role.
//

import SwiftUI
import SwiftData

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        tabs
            // Rides above whichever tab is showing, so the catalog download is
            // visible without blocking anything.
            // The bar observes the controller itself. Reading `phase` here
            // would subscribe the whole tab root, re-rendering every tab on
            // each ingest batch — straight into anything being scrolled.
            .overlay(alignment: .top) { CatalogSyncBar() }
            .task {
                await CatalogSyncController.shared.syncIfNeeded(
                    container: modelContext.container
                )
            }
    }

    private var tabs: some View {
        TabView {
            Tab("Collection", systemImage: "square.grid.3x3.fill") {
                CollectionsView()
            }

            Tab("Decks", systemImage: "rectangle.stack.fill") {
                DecksView()
            }

            Tab("History", systemImage: "clock.arrow.circlepath") {
                HistoryView()
            }

            Tab("Search", systemImage: "magnifyingglass") {
                SearchView()
            }
        }
    }
}

#Preview {
    MainTabView()
        .modelContainer(for: [MTGCollection.self, CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
