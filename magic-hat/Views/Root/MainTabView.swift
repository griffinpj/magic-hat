//
//  MainTabView.swift
//  magic-hat
//
//  Root tab scaffold. Uses the modern `Tab` API so the app picks up the
//  native Liquid Glass tab bar on iOS 26.
//

import SwiftUI
import SwiftData

struct MainTabView: View {
    var body: some View {
        tabs
            // The bar observes the controller itself. Reading `phase` here
            // would subscribe the whole tab root, re-rendering every tab on
            // each ingest batch — straight into anything being scrolled.
            // The sync is started by RootView.
            .overlay(alignment: .top) { CatalogSyncBar() }
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
        .modelContainer(for: [MTGCollection.self, CollectionEntry.self, CardMeta.self, AuditRecord.self, CardRuling.self], inMemory: true)
}
