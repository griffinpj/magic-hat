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
    }

    // The catalog sync's narration rides above the tab bar, inside each
    // tab, as a bottom safe-area bar: a pill that comes with the sync and
    // goes with it. Not the tab view's bottom accessory: that slot is for
    // a control that stays (Music's mini-player), and it kept showing the
    // last status line after the sync had gone idle — reproduced with
    // `-uitest-fake-sync`. Not an overlay at the top either, where it
    // covered titles and buttons. The bar observes the controller itself:
    // reading `phase` here would subscribe the whole tab root, re-rendering
    // every tab on each ingest batch — straight into anything being
    // scrolled. The sync is started by RootView.
    private var tabs: some View {
        TabView {
            Tab("Collection", systemImage: "square.grid.3x3.fill") {
                CollectionsView().catalogSyncBar()
            }

            Tab("Decks", systemImage: "rectangle.stack.fill") {
                DecksView().catalogSyncBar()
            }

            Tab("History", systemImage: "clock.arrow.circlepath") {
                HistoryView().catalogSyncBar()
            }

            Tab("Search", systemImage: "magnifyingglass") {
                SearchView().catalogSyncBar()
            }
        }
    }
}

#Preview {
    MainTabView()
        .modelContainer(for: [MTGCollection.self, CollectionEntry.self, CardMeta.self, AuditRecord.self, CardRuling.self], inMemory: true)
}
