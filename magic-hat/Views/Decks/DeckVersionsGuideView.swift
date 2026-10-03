//
//  DeckVersionsGuideView.swift
//  magic-hat
//
//  How a deck's Versions work, from the "i" in the screen's bar: saving,
//  restoring, branches — and, since it looks like History and isn't, what
//  each of the two keeps, where they meet, and where they don't. The same
//  sheet of short sections as History's guide (GuideRow), with the two
//  set side by side row by row.
//

import SwiftUI

struct DeckVersionsGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    GuideRow(icon: "checkmark.circle", title: "Save a version",
                             text: "A version is the deck's whole list at a moment you choose: before a big change, after a good night of games. Name it or don't. Until you save, your edits show under Unsaved Changes.")
                    GuideRow(icon: "arrow.left.arrow.right", title: "See what changed",
                             text: "Open Unsaved Changes, or any version, for the cards added, removed, changed in count or moved between boards, and what that did to the card count, lands, value and average mana value.")
                    GuideRow(icon: "arrow.uturn.backward.circle", title: "Restore",
                             text: "Puts an older version's list back as a new version on top. Nothing is rewound or lost: the versions in between stay where they are.")
                    GuideRow(icon: "arrow.uturn.backward", title: "Discard Changes",
                             text: "Drops what is unsaved and returns the list to the last version. This is the one thing here that can't be taken back.")
                } header: {
                    Text("Versions")
                }

                Section {
                    GuideRow(icon: "arrow.triangle.branch", title: "Another take on the deck",
                             text: "A branch is the same deck going a different way: a budget build, a different package. Each branch has its own versions. New Branch starts one from the list as it is now, or from any version's page.")
                    GuideRow(icon: "arrow.left.arrow.right.circle", title: "Switch",
                             text: "Changes the deck's list to that branch's newest version. Anything unsaved is saved automatically on the branch you are leaving, so it is there when you come back.")
                    GuideRow(icon: "tag", title: "Where branches meet",
                             text: "A tag on a version shows another branch that sits at that version, or splits off after it. “2 versions of its own · 1 behind” compares a branch with the one you are on.")
                    GuideRow(icon: "trash", title: "Delete a branch",
                             text: "Removes the branch and the versions only it had. Versions shared with another branch stay. The branch you are on can't be deleted.")
                } header: {
                    Text("Branches")
                }

                Section {
                    CompareRow(topic: "What it keeps",
                               versions: "The deck's list: which cards it wants, how many, on which board.",
                               history: "Your cards: every copy added, removed or moved, in collections, lists and built decks.")
                    CompareRow(topic: "Scope",
                               versions: "One deck. Each deck has its own versions and branches.",
                               history: "Everything, in one timeline across all collections and decks.")
                    CompareRow(topic: "When it records",
                               versions: "When you save, and automatically before a switch, a restore or a new branch, and when the deck is built.",
                               history: "Every change to your cards, as it happens.")
                    CompareRow(topic: "Going back",
                               versions: "Restore: a new version with the old list. Always works; a built deck is rebuilt to match.",
                               history: "Undo and Redo: cards move back. Can be blocked if the cards are no longer where they were.")
                    CompareRow(topic: "Branches",
                               versions: "You make and name them.",
                               history: "They appear when you undo and then change something.")
                } header: {
                    Text("Versions and the History Tab")
                } footer: {
                    Text("They are separate on purpose. A deck's list is a plan and can be rewritten freely; your cards are real, so History only ever moves them and always adds up.")
                }

                Section {
                    GuideRow(icon: "list.bullet.rectangle", title: "List edits are not in History",
                             text: "Adding to a deck's list, saving, restoring and switching branches move no cards, so the History tab shows none of it, and Undo there never changes a deck's list.")
                    GuideRow(icon: "clock.arrow.circlepath", title: "Saving moves nothing",
                             text: "Saving a version, naming things and making a branch from the list as it is never touch your cards.")
                } header: {
                    Text("What Stays Separate")
                }

                Section {
                    GuideRow(icon: "hammer", title: "A built deck follows its list",
                             text: "When a deck is built, Switch, Restore and Discard change which cards it needs. The deck is taken apart, the list changes, and it is built again from the same collections. You are asked first, and both steps appear in History, where they can be undone.")
                    GuideRow(icon: "exclamationmark.circle", title: "If the new list needs cards you don't have",
                             text: "The rebuild takes what your collection can supply and says how many are missing. They show as missing on the Cards tab, as after any build.")
                    GuideRow(icon: "checkmark.circle", title: "Building saves a version",
                             text: "Building a deck that already has versions saves an automatic one, so the list as built is kept.")
                    GuideRow(icon: "rectangle.stack.badge.minus", title: "Deleting the deck",
                             text: "Deleting a deck is a History action. Undo it there and the deck comes back with its list, its versions and its branches.")
                    GuideRow(icon: "externaldrive", title: "Backups",
                             text: "Both travel in a backup: the ledger, and every deck's versions and branches.")
                } header: {
                    Text("Where They Meet")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("About Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("versions-guide-done")
                }
            }
        }
    }
}

/// One point of comparison: the topic, then what Versions does and what
/// History does, each led by its own symbol so the two columns of meaning
/// read down the page without a table that a phone's width can't hold.
private struct CompareRow: View {
    let topic: String
    let versions: String
    let history: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic).font(.subheadline.weight(.semibold))
            side("arrow.triangle.branch", "Versions", versions)
            side("clock.arrow.circlepath", "History", history)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func side(_ icon: String, _ name: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 22)
                .padding(.top, 2)
            Text("\(Text(name).fontWeight(.medium).foregroundStyle(.primary))  \(text)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    DeckVersionsGuideView()
}
