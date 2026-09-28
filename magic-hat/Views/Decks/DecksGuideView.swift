//
//  DecksGuideView.swift
//  magic-hat
//
//  How the Decks tab is organised, from the ⓘ in its bar: folders, moving
//  decks by drag or by Move, selecting several, the view options, and
//  where each deck's own actions are. Information only, in the shape of
//  History's guide.
//

import SwiftUI

struct DecksGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Folders") {
                    GuideRow(icon: "folder.badge.plus", title: "Make a folder",
                             text: "Tap + and New Folder. Folders can hold decks and other folders, as deep as you like.")
                    GuideRow(icon: "hand.draw", title: "Drag into a folder",
                             text: "Touch and hold a deck until it lifts, then drag it onto a folder. Folders move the same way, into other folders.")
                    GuideRow(icon: "folder", title: "Move without dragging",
                             text: "Touch and hold a deck or folder and choose Move…, or swipe left on it in List view. Pick where it goes, or make a new folder there.")
                    GuideRow(icon: "trash", title: "Deleting a folder",
                             text: "Only the folder goes. The decks and folders in it move up a level; no deck is ever deleted with its folder.")
                }

                Section("Several at Once") {
                    GuideRow(icon: "checkmark.circle", title: "Select decks",
                             text: "In the … menu, choose Select Decks, tap the ones you want, then Move or Delete them together.")
                }

                Section("Viewing") {
                    GuideRow(icon: "square.grid.2x2", title: "Icons or list",
                             text: "The … menu switches between big deck tiles and a compact list, and sorts by name, date or format. Folders always come first.")
                    GuideRow(icon: "magnifyingglass", title: "Search everywhere",
                             text: "Search looks through every folder at once, and shows which folder each deck is in.")
                }

                Section("A Deck") {
                    GuideRow(icon: "hand.tap", title: "Open, rename, delete",
                             text: "Tap a deck to open it. Touch and hold it for Rename, Move and Delete. Deleting a built deck puts its cards back in their collections first.")
                    GuideRow(icon: "plus", title: "New decks",
                             text: "A deck you create or import lands in the folder you're looking at.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Managing Decks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("decks-guide-done")
                }
            }
        }
    }
}
