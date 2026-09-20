//
//  SearchView.swift
//  magic-hat
//
//  Placeholder for the Search tab (Scryfall card search comes later).
//

import SwiftUI

struct SearchView: View {
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Search Coming Soon",
                systemImage: "magnifyingglass",
                description: Text("Search Scryfall for any Magic card.")
            )
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Cards, sets, types…")
        }
    }
}

#Preview {
    SearchView()
}
