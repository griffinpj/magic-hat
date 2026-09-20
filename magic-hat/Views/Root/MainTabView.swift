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
    var body: some View {
        TabView {
            Tab("Collection", systemImage: "square.grid.3x3.fill") {
                CollectionView()
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
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
