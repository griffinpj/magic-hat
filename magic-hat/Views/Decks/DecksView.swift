//
//  DecksView.swift
//  magic-hat
//
//  Placeholder for the Decks tab (deck building comes later).
//

import SwiftUI

struct DecksView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Decks Yet",
                systemImage: "rectangle.stack",
                description: Text("Build decks from cards in your collection.")
            )
            .navigationTitle("Decks")
        }
    }
}

#Preview {
    DecksView()
}
