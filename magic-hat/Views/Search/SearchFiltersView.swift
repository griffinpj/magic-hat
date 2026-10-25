//
//  SearchFiltersView.swift
//  magic-hat
//
//  The Filters sheet shown over results: the same sections as the landing
//  screen, editing a draft committed on Done. Cancel throws the draft away
//  on purpose; with edits in it the sheet can't be swiped away, since a
//  swipe used to discard them without a word. Reset is in the bottom bar.
//

import SwiftUI

struct SearchFiltersView: View {
    @Binding var query: CardSearchQuery
    var context: FilterContext = .scryfall

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CardSearchQuery
    @FocusState private var focused: FilterField?

    init(query: Binding<CardSearchQuery>, context: FilterContext = .scryfall) {
        _query = query
        self.context = context
        _draft = State(initialValue: query.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    SearchFilterSections(query: $draft, focused: $focused, context: context, showsSort: false,
                                         scrollProxy: proxy)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("filters-cancel")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset") {
                        // A set's page keeps its set: it is the scope.
                        let sets = draft.sets
                        draft.clearFilters()
                        if context == .set { draft.sets = sets }
                    }
                    .disabled(context == .set ? draft.activeFilterCountBesidesSets == 0 : !draft.hasFilters)
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
        .interactiveDismissDisabled(draft != query)
    }
}

#Preview {
    SearchFiltersView(query: .constant(CardSearchQuery()))
}
