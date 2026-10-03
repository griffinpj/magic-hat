//
//  DeckVersionsView.swift
//  magic-hat
//
//  A deck list's own history (see DeckVersion): what is unsaved, the
//  branches, and the current branch's versions newest first on History's
//  rail. Pushed from the deck's "…" menu and its Details page.
//
//  Git's ideas in the words of the things on screen, top to bottom in the
//  order a person needs them:
//
//  - **Unsaved Changes** — `git status`. "+3 −2 since Budget build", a tap
//    for the card-by-card diff, Discard Changes; Save Version… is the one
//    prominent button, in the bottom bar, and only there when there is
//    something to save (its alert takes an optional name — the commit
//    message).
//  - **Branches** — the current one checked, each other with Switch and
//    how it stands against this one ("2 versions of its own · 1 behind");
//    swipe or long-press for Rename, Compare, Delete; New Branch… last.
//    Switching never asks: what is unsaved is saved on the branch being
//    left, and the footer says so.
//  - **Versions on Main** — `git log`. A row per version on the rail, with
//    what it changed ("+3 −2 · 100 cards") and a tag where another branch
//    sits or splits off. A row opens the version: its changes against the
//    one before, Restore This Version, New Branch from Here.
//
//  A built deck's cards follow its list: Switch, Restore and Discard on a
//  deck that is built take it apart and build it again from the new list
//  (DeckVersionController.changingList). Switch asks first then — cards
//  are about to move — and every confirmation says so; a pill shows while
//  it runs, and the toast says what was built and what is missing.
//
//  An "i" in the bar opens DeckVersionsGuideView: how it works, and what
//  is and isn't shared with the History tab.
//
//  No graph of lanes, as in History: one branch's line is what is being
//  looked at, the others are a list, and a tag says where they meet.
//

import SwiftUI
import SwiftData

/// A screen pushed from Versions. Pushed with destination links and
/// `navigationDestination(item:)`, never `NavigationLink(value:)`: the
/// Decks tab's stack has a typed path (`[DeckRoute]`), which drops values
/// of any other type without a word.
enum DeckVersionRoute: Hashable, Identifiable {
    case version(UUID)
    case compare(from: DeckListRef, to: DeckListRef, title: String)

    var id: Self { self }

    @MainActor @ViewBuilder func destination(deckID: UUID) -> some View {
        switch self {
        case .version(let id):
            DeckVersionCompareView(deckID: deckID, from: .parent(of: id), to: .version(id), title: "Version", versionID: id)
        case .compare(let from, let to, let title):
            DeckVersionCompareView(deckID: deckID, from: from, to: to, title: title, versionID: nil)
        }
    }
}

struct DeckVersionsView: View {
    let deckID: UUID

    @Environment(\.modelContext) private var modelContext
    @State private var snapshot: DeckVersionsSnapshot?
    @State private var hasLoaded = false
    @State private var saving = false
    @State private var saveName = ""
    @State private var branching = false
    @State private var branchName = ""
    @State private var renaming: DeckBranchInfo?
    @State private var renameText = ""
    @State private var deleting: DeckBranchInfo?
    @State private var confirmDiscard = false
    @State private var done = 0
    @State private var toast: String?
    @State private var error: String?
    /// A screen pushed from a menu, where a link can't live.
    @State private var pushed: DeckVersionRoute?
    @State private var showGuide = false
    /// A switch waiting on its confirmation (a built deck only).
    @State private var switching: DeckBranchInfo?
    /// A list change that is moving cards.
    @State private var isRebuilding = false

    private var deckTracker: DeckChangeTracker { .shared }

    var body: some View {
        dialogs(screen)
    }

    /// The list in its bars; the alerts are applied apart (`dialogs`), one
    /// expression being more than the type checker will take.
    private var screen: some View {
        Group {
            if let snapshot {
                list(snapshot)
            } else if hasLoaded {
                ContentUnavailableView("Deck Not Found", systemImage: "rectangle.stack")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Versions")
        .navigationSubtitle(snapshot?.deckName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushed) { $0.destination(deckID: deckID) }
        .toolbar {
            // How versions and branches work, and how they differ from
            // the History tab; information only, as History's own "i".
            ToolbarItem(placement: .topBarTrailing) {
                Button("About Versions", systemImage: "info.circle") { showGuide = true }
                    .accessibilityIdentifier("versions-info")
            }
        }
        .sheet(isPresented: $showGuide) { DeckVersionsGuideView() }
        .task(id: deckTracker.revision) { await load() }
        .sensoryFeedback(.success, trigger: done)
        .safeAreaBar(edge: .bottom) { saveBar }
        .overlay(alignment: .top) { toastView }
        .overlay(alignment: .bottom) {
            if isRebuilding { RebuildingPill() }
        }
        .animation(.snappy, value: toast)
        .animation(.default, value: isRebuilding)
        .disabled(isRebuilding)
    }

    private func dialogs(_ content: some View) -> some View {
        content
        .alert("Save Version", isPresented: $saving) {
            TextField("Name (optional)", text: $saveName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks the list as it is now, so you can compare with it or come back to it.")
        }
        .alert("New Branch", isPresented: $branching) {
            TextField("Name", text: $branchName)
            Button("Create") { run("On \(branchName.trimmingCharacters(in: .whitespaces))") {
                try DeckVersionController.createBranch(deckID: deckID, name: branchName, context: modelContext)
            } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Another take on this deck, starting from the list as it is now. \(snapshot?.current?.name ?? "This branch") stays as it was last saved.")
        }
        .alert("Rename Branch", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { branch in
            TextField("Name", text: $renameText)
            Button("Save") { run(nil) { try DeckVersionController.renameBranch(branch.id, to: renameText, context: modelContext) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { branch in
            Button("Delete Branch", role: .destructive) {
                run("Deleted \(branch.name)") { try DeckVersionController.deleteBranch(branch.id, context: modelContext) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { branch in
            Text(branch.ahead == 0 ? "Its versions are all on other branches; nothing else is removed."
                 : "Its \(branch.ahead == 1 ? "version" : "\(branch.ahead) versions") that no other branch has will be removed with it.")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(snapshot?.isBuilt == true ? "Discard and Rebuild" : "Discard Changes", role: .destructive) {
                change("Changes discarded") { try DeckVersionController.discardChanges(deckID: deckID, context: modelContext) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The list goes back to “\(snapshot?.versions.first?.title ?? "the last version")”. This can't be undone."
                 + (snapshot.map { DeckRebuildText.note(builtCopies: $0.builtCopies) } ?? ""))
        }
        .confirmationDialog("Switch to “\(switching?.name ?? "")”?", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
                            titleVisibility: .visible, presenting: switching) { branch in
            Button("Switch and Rebuild") { switchTo(branch) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(DeckRebuildText.note(builtCopies: snapshot?.builtCopies ?? 0).trimmingCharacters(in: .whitespaces))
        }
        .alert("Couldn't Do That", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    // MARK: List

    private func list(_ snapshot: DeckVersionsSnapshot) -> some View {
        List {
            unsavedSection(snapshot)
            branchesSection(snapshot)
            versionsSection(snapshot)
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder private func unsavedSection(_ snapshot: DeckVersionsSnapshot) -> some View {
        Section {
            if snapshot.unsaved.isEmpty {
                Label {
                    Text(snapshot.isUntracked ? "Nothing in the list yet" : "Everything is saved")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: snapshot.isUntracked ? "circle.dashed" : "checkmark.circle.fill")
                        .foregroundStyle(snapshot.isUntracked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.green))
                }
                .accessibilityIdentifier("versions-clean")
            } else {
                NavigationLink {
                    // Against the version the branch was last saved at.
                    DeckVersionRoute.compare(from: snapshot.versions.first.map { .version($0.id) } ?? .parent(of: deckID), to: .working,
                                             title: "Unsaved Changes").destination(deckID: deckID)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        ChangeCounts(added: snapshot.unsaved.added, removed: snapshot.unsaved.removed, moved: snapshot.unsaved.moved)
                            .font(.body.weight(.semibold))
                        Text(snapshot.isUntracked ? "Not saved yet · \(cards(snapshot.workingCardCount))"
                             : "since “\(snapshot.versions.first?.title ?? "")” · \(cards(snapshot.workingCardCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("versions-unsaved")
                if !snapshot.isUntracked, !snapshot.isLocked {
                    Button("Discard Changes", systemImage: "arrow.uturn.backward", role: .destructive) { confirmDiscard = true }
                        .accessibilityIdentifier("versions-discard")
                }
            }
        } header: {
            Text("Unsaved Changes")
        }
    }

    @ViewBuilder private func branchesSection(_ snapshot: DeckVersionsSnapshot) -> some View {
        Section {
            ForEach(snapshot.branches) { branch in
                branchRow(branch, locked: snapshot.isLocked, built: snapshot.isBuilt)
            }
            Button("New Branch…", systemImage: "plus") {
                branchName = ""
                branching = true
            }
            .accessibilityIdentifier("versions-new-branch")
        } header: {
            Text("Branches")
        } footer: {
            Text(snapshot.others.isEmpty
                 ? "A branch is another take on the deck — a budget build, a different commander's package — kept beside this one."
                 : "Switching changes the deck's list to that branch. Anything unsaved here is saved on \(snapshot.current?.name ?? "this branch") first."
                 + (snapshot.isBuilt ? " This deck is built, so its cards go back to your collection and the new list is built from it." : ""))
        }
    }

    private func branchRow(_ branch: DeckBranchInfo, locked: Bool, built: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(branch.isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(branch.name)
                    .fontWeight(branch.isCurrent ? .semibold : .regular)
                Text(branchCaption(branch))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if branch.isCurrent {
                Text("Current")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            } else {
                Button("Switch") {
                    // Cards are about to move on a built deck: ask first.
                    if built { switching = branch } else { switchTo(branch) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .font(.subheadline.weight(.semibold))
                .disabled(locked)
                .accessibilityIdentifier("versions-switch-\(branch.name)")
            }
        }
        .contentShape(Rectangle())
        .contextMenu { branchMenu(branch) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !branch.isCurrent {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = branch }
            }
            Button("Rename", systemImage: "pencil") { beginRename(branch) }
                .tint(.orange)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("versions-branch-\(branch.name)")
    }

    @ViewBuilder private func branchMenu(_ branch: DeckBranchInfo) -> some View {
        Button("Rename…", systemImage: "pencil") { beginRename(branch) }
        if !branch.isCurrent {
            Button("Compare with Current List", systemImage: "arrow.left.arrow.right") {
                pushed = .compare(from: .branch(branch.id), to: .working, title: "Compare")
            }
            Button("Delete Branch", systemImage: "trash", role: .destructive) { deleting = branch }
        }
    }

    private func branchCaption(_ branch: DeckBranchInfo) -> String {
        var parts = [branch.caption]
        if let updated = branch.updatedAt {
            parts.append(updated.formatted(.relative(presentation: .named)))
        } else {
            parts = ["Nothing saved yet"]
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func versionsSection(_ snapshot: DeckVersionsSnapshot) -> some View {
        Section {
            if snapshot.versions.isEmpty {
                Text("Save a version to mark a point you can compare with and come back to.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(snapshot.versions.enumerated()), id: \.element.id) { index, version in
                NavigationLink {
                    DeckVersionRoute.version(version.id).destination(deckID: deckID)
                } label: {
                    VersionRow(version: version,
                               mark: RailMark(above: index == 0 ? nil : .solid,
                                              below: index == snapshot.versions.count - 1 ? nil : .solid,
                                              dot: index == 0 ? .head : .applied, stub: version.marks.contains { if case .fork = $0 { return true }; return false }))
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
                .accessibilityIdentifier("versions-row-\(index)")
            }
        } header: {
            Text("Versions on \(snapshot.current?.name ?? DeckBranch.defaultName)")
        } footer: {
            if !snapshot.versions.isEmpty {
                Text("Newest first. Open a version to see what it changed, restore it, or start a branch from it.")
            }
        }
    }

    /// Save Version…, when there is something to save: the screen's one
    /// prominent action, where the thumb is.
    @ViewBuilder private var saveBar: some View {
        if let snapshot, !snapshot.unsaved.isEmpty {
            Button {
                saveName = ""
                saving = true
            } label: {
                Label("Save Version…", systemImage: "checkmark.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityIdentifier("versions-save")
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Label {
                Text(toast)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(2))
                self.toast = nil
            }
            .accessibilityIdentifier("versions-toast")
        }
    }

    // MARK: Work

    private func cards(_ n: Int) -> String { n == 1 ? "1 card" : "\(n) cards" }

    private func beginRename(_ branch: DeckBranchInfo) {
        renameText = branch.name
        renaming = branch
    }

    private func load() async {
        let store = DeckStore.shared(for: modelContext.container)
        let fetched = try? await store.versions(deckID: deckID)
        guard !Task.isCancelled else { return }
        snapshot = fetched
        hasLoaded = true
    }

    private func save() {
        let name = saveName
        run(name.trimmingCharacters(in: .whitespaces).isEmpty ? "Version saved" : "Saved “\(name.trimmingCharacters(in: .whitespaces))”") {
            try DeckVersionController.save(deckID: deckID, name: name, context: modelContext)
        }
    }

    private func switchTo(_ branch: DeckBranchInfo) {
        change("On \(branch.name)") { try DeckVersionController.switchBranch(deckID: deckID, to: branch.id, context: modelContext) }
    }

    /// A write that changes the list: on a built deck the deck is taken
    /// apart and rebuilt around it, and the toast says how that went.
    private func change(_ message: String, _ work: @escaping () throws -> Void) {
        let container = modelContext.container
        isRebuilding = snapshot?.isBuilt ?? false
        Task {
            defer { isRebuilding = false }
            do {
                let rebuild = try await DeckVersionController.changingList(deckID: deckID, container: container, work)
                done += 1
                toast = rebuild.map { "\(message) · \(DeckRebuildText.result($0))" } ?? message
                AccessibilityNotification.Announcement(toast ?? message).post()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// A write, then the haptic and what it did; the tracker's bump
    /// reloads the screen.
    private func run(_ message: String?, _ work: () throws -> Void) {
        do {
            try work()
            done += 1
            if let message {
                toast = message
                AccessibilityNotification.Announcement(message).post()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What the confirmations and toasts say about a built deck.
enum DeckRebuildText {
    /// " This deck is built: …" — appended to a confirmation; empty when
    /// the deck isn't built.
    static func note(builtCopies: Int) -> String {
        guard builtCopies > 0 else { return "" }
        let cards = builtCopies == 1 ? "Its 1 built card goes" : "Its \(builtCopies) built cards go"
        return " This deck is built. \(cards) back to your collection and the new list is built from it; both steps are in History."
    }

    /// "rebuilt 98" / "rebuilt 95, 3 missing".
    static func result(_ rebuild: DeckVersionController.Rebuild) -> String {
        rebuild.missing > 0 ? "rebuilt \(rebuild.built), \(rebuild.missing) missing" : "rebuilt \(rebuild.built)"
    }
}

/// Floats over the screen while a built deck is taken apart and rebuilt.
struct RebuildingPill: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Rebuilding…").font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 90)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("versions-rebuilding")
    }
}

/// "+3 −2", green and red as History has them; "2 moved" in secondary.
struct ChangeCounts: View {
    let added: Int
    let removed: Int
    var moved = 0

    var body: some View {
        HStack(spacing: 6) {
            if added > 0 { Text("+\(added)").foregroundStyle(.green) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
            if moved > 0 { Text("\(moved) moved").foregroundStyle(.secondary) }
            if added == 0, removed == 0, moved == 0 { Text("No changes").foregroundStyle(.secondary) }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

/// One version on the rail: what it is called, what it changed, when —
/// and a tag where another branch sits or splits off.
private struct VersionRow: View {
    let version: DeckVersionInfo
    let mark: RailMark

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: 20, height: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(version.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(version.isAutomatic ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    ChangeCounts(added: version.added, removed: version.removed)
                    Text("· \(version.cardCount == 1 ? "1 card" : "\(version.cardCount) cards")")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
                Text(version.createdAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !version.marks.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(version.marks.prefix(3).enumerated()), id: \.offset) { _, mark in
                            tag(mark)
                        }
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 12)
        .background(alignment: .leading) {
            HistoryRail(mark: mark, emphasized: true)
                .frame(width: 20)
        }
        .accessibilityElement(children: .combine)
    }

    private func tag(_ mark: DeckVersionInfo.Mark) -> some View {
        let (name, symbol): (String, String) = {
            switch mark {
            case .tip(let name): return (name, "tag")
            case .fork(let name): return (name, "arrow.triangle.branch")
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(name).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .accessibilityLabel(mark.accessibilityLabel)
    }
}

private extension DeckVersionInfo.Mark {
    var accessibilityLabel: String {
        switch self {
        case .tip(let name): return "Branch \(name) is here"
        case .fork(let name): return "Branch \(name) splits off here"
        }
    }
}

// MARK: - Comparing

/// Two of the deck's lists, card by card: what was added, removed, changed
/// in count, moved between boards — and what that did to the totals. It is
/// the Unsaved Changes screen, a branch compared with the current list,
/// and, with `versionID`, a version's own page: its changes against the
/// one before, Restore in the bottom bar, Rename and New Branch from Here
/// in its menu.
struct DeckVersionCompareView: View {
    let deckID: UUID
    let from: DeckListRef
    let to: DeckListRef
    let title: String
    let versionID: UUID?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var comparison: DeckComparison?
    @State private var info: DeckVersionsSnapshot?
    @State private var hasLoaded = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var branching = false
    @State private var branchName = ""
    @State private var confirmRestore = false
    @State private var done = 0
    @State private var error: String?
    @State private var pushed: DeckVersionRoute?
    @State private var isRebuilding = false

    private var deckTracker: DeckChangeTracker { .shared }
    private var version: DeckVersionInfo? { versionID.flatMap { id in info?.versions.first { $0.id == id } } }
    /// The newest version of the current branch with nothing unsaved over
    /// it is the list already: nothing to restore.
    private var isCurrentList: Bool {
        guard let versionID, let info else { return false }
        return info.versions.first?.id == versionID && info.unsaved.isEmpty
    }

    var body: some View {
        Group {
            if let comparison {
                list(comparison)
            } else if hasLoaded {
                ContentUnavailableView("Nothing to Compare", systemImage: "arrow.left.arrow.right")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if versionID != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Rename…", systemImage: "pencil") {
                            renameText = version?.isAutomatic == true ? "" : (version?.title ?? "")
                            renaming = true
                        }
                        Button("New Branch from Here…", systemImage: "arrow.triangle.branch") {
                            branchName = ""
                            branching = true
                        }
                        .disabled(info?.isLocked ?? true)
                        Button("Compare with Current List", systemImage: "arrow.left.arrow.right") {
                            pushed = .compare(from: to, to: .working, title: "Compare")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("version-menu")
                }
            }
        }
        .navigationDestination(item: $pushed) { $0.destination(deckID: deckID) }
        .safeAreaBar(edge: .bottom) { restoreBar }
        .task(id: deckTracker.revision) { await load() }
        .sensoryFeedback(.success, trigger: done)
        .alert("Rename Version", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Save") { attempt { try DeckVersionController.renameVersion(versionID!, to: renameText, context: modelContext) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Branch", isPresented: $branching) {
            TextField("Name", text: $branchName)
            Button("Create") {
                let name = branchName
                change(precheck: { try DeckVersionController.checkBranchName(name, deckID: deckID, context: modelContext) }) {
                    try DeckVersionController.createBranch(deckID: deckID, name: name, from: versionID, context: modelContext)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Starts a branch at this version and switches the deck's list to it. Anything unsaved is saved on \(info?.current?.name ?? "the current branch") first."
                 + DeckRebuildText.note(builtCopies: info?.builtCopies ?? 0))
        }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button(info?.isBuilt == true ? "Restore and Rebuild" : "Restore") {
                change { try DeckVersionController.restore(versionID: versionID!, context: modelContext) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The deck's list becomes this version's, saved as a new version on \(info?.current?.name ?? "the current branch"). Nothing is lost: what is there now stays in the branch's versions."
                 + DeckRebuildText.note(builtCopies: info?.builtCopies ?? 0))
        }
        .overlay(alignment: .bottom) { if isRebuilding { RebuildingPill() } }
        .animation(.default, value: isRebuilding)
        .disabled(isRebuilding)
        .alert("Couldn't Do That", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func list(_ comparison: DeckComparison) -> some View {
        List {
            Section {
                if let version {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(version.title).font(.headline)
                        Text(version.createdAt, format: .dateTime.weekday().day().month().year().hour().minute())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(comparison.toTitle).font(.headline)
                        Text(comparison.fromTitle == DeckComparison.nothing ? "Nothing saved to compare with yet"
                             : "compared with “\(comparison.fromTitle)”")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                total("Cards", "\(comparison.before.cards)", "\(comparison.after.cards)")
                total("Lands", "\(comparison.before.lands)", "\(comparison.after.lands)")
                total("Value", PriceFormat.whole(comparison.before.value), PriceFormat.whole(comparison.after.value))
                total("Average mana value", String(format: "%.2f", comparison.before.averageManaValue),
                      String(format: "%.2f", comparison.after.averageManaValue))
            } footer: {
                if versionID != nil {
                    Text(comparison.fromTitle == DeckComparison.nothing ? "The first version saved on this deck."
                         : "Against the version before it, “\(comparison.fromTitle)”.")
                }
            }

            if comparison.isEmpty {
                Section {
                    Label("The two lists are the same", systemImage: "equal.circle")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(comparison.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ChangeRow(item: item)
                    }
                } header: {
                    Text("\(groupTitle(group.kind)) · \(group.copies)")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// "Cards   99 → 100", the after side plain when nothing moved.
    private func total(_ label: String, _ before: String, _ after: String) -> some View {
        LabeledContent(label) {
            if before == after {
                Text(after)
            } else {
                Text("\(Text(before).foregroundStyle(.tertiary)) → \(Text(after).foregroundStyle(.primary))")
            }
        }
        .monospacedDigit()
    }

    private func groupTitle(_ kind: DeckComparison.Group.Kind) -> String {
        switch kind {
        case .added: return "Added"
        case .removed: return "Removed"
        case .changed: return "Count Changed"
        case .moved: return "Moved"
        }
    }

    @ViewBuilder private var restoreBar: some View {
        if versionID != nil, let info, !info.isLocked, !isCurrentList {
            Button {
                confirmRestore = true
            } label: {
                Label("Restore This Version", systemImage: "arrow.uturn.backward.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityIdentifier("version-restore")
        }
    }

    private func load() async {
        let store = DeckStore.shared(for: modelContext.container)
        let compared = try? await store.compare(deckID: deckID, from: from, to: to)
        let snapshot = try? await store.versions(deckID: deckID)
        guard !Task.isCancelled else { return }
        comparison = compared
        info = snapshot
        hasLoaded = true
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
            done += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A write that changes the list, then back to Versions: a built deck
    /// is taken apart and rebuilt around it. `precheck` is what could
    /// refuse the write, tried before any card moves.
    private func change(precheck: () throws -> Void = {}, _ work: @escaping () throws -> Void) {
        do { try precheck() } catch { self.error = error.localizedDescription; return }
        let container = modelContext.container
        isRebuilding = info?.isBuilt ?? false
        Task {
            defer { isRebuilding = false }
            do {
                try await DeckVersionController.changingList(deckID: deckID, container: container, work)
                done += 1
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A card and what happened to it between the two lists.
private struct ChangeRow: View {
    let item: DeckComparison.Item

    var body: some View {
        HStack(spacing: 8) {
            CardRowLead(item: item.card) {
                Text(item.card.typeLine ?? item.change.row.deckBoard.label)
            }
            Spacer(minLength: 8)
            trailing
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("version-change-\(item.card.name)")
    }

    @ViewBuilder private var trailing: some View {
        switch item.change.kind {
        case .added:
            Text("+\(item.change.to)").foregroundStyle(.green)
        case .removed:
            Text("−\(item.change.from)").foregroundStyle(.red)
        case .count:
            Text("\(item.change.from) → \(item.change.to)")
                .foregroundStyle(item.change.delta > 0 ? .green : .red)
        case .moved(let from):
            VStack(alignment: .trailing, spacing: 1) {
                Text("×\(item.change.to)").foregroundStyle(.secondary)
                Text("\(from.label) → \(item.change.row.deckBoard.label)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
