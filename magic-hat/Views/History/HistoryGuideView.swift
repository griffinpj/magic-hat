//
//  HistoryGuideView.swift
//  magic-hat
//
//  How History works, from the "i" in its bar: what is recorded, Undo and
//  Redo, what a branch is and how to get back to one, and a key to the
//  rail. Information only — nothing here changes the ledger. A sheet of
//  short sections in a grouped list, the shape of a Settings help page;
//  the rail's marks are drawn with HistoryRail itself so the key can
//  never drift from the list.
//

import SwiftUI

struct HistoryGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    GuideRow(icon: "clock.arrow.circlepath", title: "Every change is kept",
                             text: "Imports, adds, edits, removals, deleted collections, and cards moved by building or taking apart a deck are recorded as one row each, newest first. Deck list edits aren't recorded: a list is a wish, not cards.")
                    GuideRow(icon: "hand.tap", title: "Open a row",
                             text: "Tap any row to see the cards it changed and the one thing you can do with it from where you are.")
                }

                Section("Undo and Redo") {
                    GuideRow(icon: "arrow.uturn.backward", title: "Undo",
                             text: "Takes back the newest applied action. Tap again to keep going back — any number of steps.")
                    GuideRow(icon: "arrow.uturn.forward", title: "Redo",
                             text: "Puts back what you undid, in order. Undone rows stay in the list, dimmed, above the ones still applied.")
                    GuideRow(icon: "hand.point.up.left", title: "Undo Through Here",
                             text: "Touch and hold a row, or open it, to undo or redo straight to that point in one go.")
                }

                Section {
                    GuideRow(icon: "arrow.triangle.branch", title: "A new change starts a branch",
                             text: "Undo a few steps, then change something. Nothing is thrown away: the steps you undid become a branch of their own, listed under the timeline.")
                    GuideRow(icon: "arrow.left.arrow.right", title: "Switch",
                             text: "Switch on a branch undoes back to where the branches split, then redoes along that branch. It says how many steps each way before you tap.")
                    GuideRow(icon: "list.bullet", title: "Redo at a fork",
                             text: "When the undone step has more than one branch after it, Redo becomes a menu: pick which branch to continue.")
                    GuideRow(icon: "pencil", title: "Name a branch",
                             text: "Use a branch's … menu to rename it. The name stays with that work as you add to it or switch away.")
                } header: {
                    Text("Branches")
                } footer: {
                    Text("History never rewrites what happened. An undo is recorded as a change of its own, so your collection always adds up to the ledger.")
                }

                Section("Reading the rail") {
                    RailKeyRow(mark: RailMark(above: .solid, below: .solid, dot: .head), emphasized: true,
                               text: "Where you are now")
                    RailKeyRow(mark: RailMark(above: .solid, below: .solid, dot: .applied), emphasized: true,
                               text: "Applied")
                    RailKeyRow(mark: RailMark(above: .dashed, below: .dashed, dot: .undone), emphasized: true,
                               text: "Undone — Redo would bring it back")
                    RailKeyRow(mark: RailMark(above: .solid, below: .solid, dot: .applied, stub: true), emphasized: true,
                               text: "A branch leaves here")
                    RailKeyRow(mark: RailMark(above: .solid, below: .solid, dot: .undone), emphasized: false,
                               text: "On another branch")
                    RailKeyRow(mark: RailMark(above: .solid, below: nil, dot: .junction), emphasized: false,
                               text: "Where a branch joins the one it split from")
                }

                Section("What can't be undone") {
                    GuideRow(icon: "rectangle.stack.badge.minus", title: "Cards in a deleted deck",
                             text: "Take a deck apart before deleting it (the app does this for you). A change whose cards would land in a deck that no longer exists is refused.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("About History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("history-guide-done")
                }
            }
        }
    }
}

private struct GuideRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct RailKeyRow: View {
    let mark: RailMark
    let emphasized: Bool
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            HistoryRail(mark: mark, emphasized: emphasized)
                .frame(width: 28, height: 44)
            Text(text).font(.subheadline)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HistoryGuideView()
}
