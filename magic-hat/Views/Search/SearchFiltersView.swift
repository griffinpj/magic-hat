//
//  SearchFiltersView.swift
//  magic-hat
//
//  The Filters sheet shown over results: the same sections as the landing
//  screen, editing a draft committed on Done. Reset is top-left; swiping
//  the sheet down discards the draft, as sheets do.
//

import SwiftUI

struct SearchFiltersView: View {
    @Binding var query: CardSearchQuery

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CardSearchQuery
    @FocusState private var focused: FilterField?

    init(query: Binding<CardSearchQuery>) {
        _query = query
        _draft = State(initialValue: query.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                SearchFilterSections(query: $draft, focused: $focused, showsSort: false)
            }
            .scrollDismissesKeyboard(.interactively)
            .filterKeyboardBar($focused)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { draft.clearFilters() }
                        .disabled(!draft.hasFilters)
                        .accessibilityIdentifier("filters-reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        query = draft
                        dismiss()
                    }
                    .accessibilityIdentifier("filters-done")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    SearchFiltersView(query: .constant(CardSearchQuery()))
}
