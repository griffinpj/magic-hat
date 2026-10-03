import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// A deck list's versions: comparing lists, and the rules that keep a
/// branch's history whole — a restore adds, a switch saves first, a
/// deleted branch takes only what was its own.
@Suite("Deck list diff")
struct DeckListDiffTests {
    private func row(_ name: String, _ qty: Int = 1, _ board: DeckBoard = .main, printing: String? = nil) -> DeckVersionRow {
        DeckVersionRow(board: board, quantity: qty, scryfallID: printing ?? "s-\(name)", oracleID: "o-\(name)", name: name)
    }

    @Test func addedRemovedCountAndMoved() {
        let old = [row("Sol Ring"), row("Opt", 2), row("Bolt", 4), row("Pyroblast", 2, .side)]
        let new = [row("Sol Ring"), row("Opt", 3), row("Counterspell"), row("Pyroblast", 2, .main)]
        let diff = DeckListDiff.between(old, new)
        #expect(diff.changes.map(\.row.name) == ["Counterspell", "Bolt", "Opt", "Pyroblast"], "added, removed, count, moved")
        #expect(diff.changes.map(\.kind) == [.added, .removed, .count, .moved(from: .side)])
        #expect(diff.added == 2 && diff.removed == 4 && diff.moved == 2, "a move is neither in nor out")
        #expect(diff.summary == "+2 −4 2 moved")
        #expect(DeckListDiff.between(old, old).isEmpty && DeckListDiff.between(old, old).summary == "No changes")
    }

    @Test func aDifferentPrintingIsNotAChange() {
        let a = [row("Sol Ring", printing: "c21"), row("Opt", 1), row("Opt", 1)]
        let b = [row("Opt", 2), row("Sol Ring", printing: "cmm")]
        #expect(DeckVersionRow.sameList(a, b) && DeckListDiff.between(a, b).isEmpty)
        #expect(DeckVersionRow.normalized(a).count == 2, "rows for one card on one board merge")
        #expect(DeckVersionRow.decode(DeckVersionRow.encode(a)) == DeckVersionRow.normalized(a))
        #expect(DeckVersionRow.playedCopies([row("A", 2), row("B", 3, .side), row("C", 1, .commander)]) == 3)
    }

    @Test func theTreeFindsPathsBasesAndOrphans() {
        let ids = (0..<6).map { _ in UUID() }
        // 0 ← 1 ← 2 ← 3 (main);  1 ← 4 ← 5 (other)
        let tree = DeckVersionTree(parents: [(ids[0], nil), (ids[1], ids[0]), (ids[2], ids[1]), (ids[3], ids[2]), (ids[4], ids[1]), (ids[5], ids[4])])
        #expect(tree.path(from: ids[3]) == [ids[3], ids[2], ids[1], ids[0]])
        #expect(tree.mergeBase(ids[3], ids[5]) == ids[1])
        #expect(tree.unreachable(from: [ids[3]]) == [ids[4], ids[5]])
        #expect(tree.unreachable(from: [ids[3], ids[5]]).isEmpty)
        #expect(tree.path(from: nil).isEmpty && tree.path(from: UUID()).isEmpty)
    }
}

@MainActor
@Suite("Deck versions", .serialized)
struct DeckVersionTests {
    private func world() throws -> (ModelContainer, UUID) {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        for (id, name, cost, price) in [("a", "Alpha", "{1}", 1.0), ("b", "Beta", "{2}", 2.0), ("c", "Gamma", "{3}", 4.0), ("l", "Plains", "", 0.1)] {
            let meta = CardMeta(scryfallID: id, name: name, fetchState: .fetched)
            meta.oracleID = "o-\(id)"
            meta.manaCost = cost
            meta.priceUSD = price
            meta.typeLine = name == "Plains" ? "Basic Land — Plains" : "Creature"
            ctx.insert(meta)
        }
        let deck = try DeckEditController.createDeck(name: "D", format: .other, commander: nil, context: ctx)
        try add("a", "Alpha", 1, to: deck.id, ctx)
        try add("l", "Plains", 10, to: deck.id, ctx)
        return (container, deck.id)
    }

    private func add(_ id: String, _ name: String, _ qty: Int, to deck: UUID, board: DeckBoard = .main, _ ctx: ModelContext) throws {
        let meta = try #require(try ctx.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { $0.scryfallID == id })).first)
        let printing = PrintingSelection(item: CardItem(meta: meta, owned: false))
        try DeckEditController.add(printing, to: deck, board: board, quantity: qty, context: ctx)
    }

    private func names(_ deck: UUID, _ container: ModelContainer) throws -> [String: Int] {
        let cards = try ModelContext(container).fetch(FetchDescriptor<DeckCard>()).filter { $0.deck?.id == deck }
        return Dictionary(cards.map { ($0.name, $0.quantity) }, uniquingKeysWith: +)
    }

    @Test func savingMarksTheListAndUnsavedChangesAreSeen() async throws {
        let (container, deck) = try world()
        let ctx = container.mainContext
        let store = DeckStore(modelContainer: container)

        var snap = try #require(try await store.versions(deckID: deck))
        #expect(snap.isUntracked && snap.versions.isEmpty && snap.unsaved.added == 11, "everything is unsaved before the first version")

        try DeckVersionController.save(deckID: deck, name: "First", context: ctx)
        snap = try #require(try await store.versions(deckID: deck))
        #expect(!snap.isUntracked && snap.unsaved.isEmpty)
        #expect(snap.branches.map(\.name) == ["Main"] && snap.current?.versionCount == 1)
        #expect(snap.versions.map(\.title) == ["First"] && snap.versions[0].summary == "+11 · 11 cards")

        try add("b", "Beta", 2, to: deck, ctx)
        snap = try #require(try await store.versions(deckID: deck))
        #expect(snap.unsaved.summary == "+2" && snap.workingCardCount == 13)
        #expect(try DeckVersionController.save(deckID: deck, kind: .auto, note: "x", onlyIfChanged: true, context: ctx) != nil)
        #expect(try DeckVersionController.save(deckID: deck, kind: .auto, note: "x", onlyIfChanged: true, context: ctx) == nil,
                "an automatic save with nothing new writes nothing")

        // Discard: back to the tip.
        try add("c", "Gamma", 1, to: deck, ctx)
        try DeckVersionController.discardChanges(deckID: deck, context: ctx)
        #expect(try names(deck, container) == ["Alpha": 1, "Plains": 10, "Beta": 2])
    }

    @Test func restoreAddsAVersionAndKeepsWhatWasUnsaved() async throws {
        let (container, deck) = try world()
        let ctx = container.mainContext
        let store = DeckStore(modelContainer: container)
        let first = try #require(try DeckVersionController.save(deckID: deck, name: "First", context: ctx))
        try add("b", "Beta", 2, to: deck, ctx)
        try DeckVersionController.save(deckID: deck, name: "With Beta", context: ctx)
        try add("c", "Gamma", 1, to: deck, ctx)       // unsaved

        try DeckVersionController.restore(versionID: first.id, context: ctx)
        #expect(try names(deck, container) == ["Alpha": 1, "Plains": 10])
        let snap = try #require(try await store.versions(deckID: deck))
        #expect(snap.versions.map(\.title) == ["Restored “First”", "Before restoring", "With Beta", "First"],
                "nothing rewound: the unsaved list and the restore are both on top")
        #expect(snap.versions[1].isAutomatic && !snap.versions[0].isAutomatic)
        #expect(snap.unsaved.isEmpty)
        #expect(snap.versions[0].summary == "−3 · 11 cards")

        // The version's own page: its changes against the one before.
        let page = try #require(try await store.compare(deckID: deck, from: .parent(of: snap.versions[2].id), to: .version(snap.versions[2].id)))
        #expect(page.groups.map(\.kind) == [.added] && page.groups[0].items.map(\.card.name) == ["Beta"])
        #expect(page.before.cards == 11 && page.after.cards == 13 && page.after.value == page.before.value + 4)
        #expect(page.before.lands == 10 && page.fromTitle == "First" && page.toTitle == "With Beta")
    }

    @Test func branchesSwitchSaveFirstAndDeleteTakesOnlyTheirOwn() async throws {
        let (container, deck) = try world()
        let ctx = container.mainContext
        let store = DeckStore(modelContainer: container)
        try DeckVersionController.save(deckID: deck, name: "First", context: ctx)

        // A branch from the list as it stands carries unsaved changes along.
        try add("b", "Beta", 2, to: deck, ctx)
        let budget = try DeckVersionController.createBranch(deckID: deck, name: "Budget", context: ctx)
        var snap = try #require(try await store.versions(deckID: deck))
        #expect(snap.current?.name == "Budget" && snap.unsaved.summary == "+2", "still unsaved, now on Budget")
        try DeckVersionController.save(deckID: deck, name: "Cheap Beta", context: ctx)
        #expect(throws: DeckVersionController.VersionError.self) { try DeckVersionController.createBranch(deckID: deck, name: "budget", context: ctx) }
        #expect(throws: DeckVersionController.VersionError.self) { try DeckVersionController.createBranch(deckID: deck, name: "  ", context: ctx) }

        // Switch with something unsaved: it is saved on Budget, and Main's list comes back.
        try add("c", "Gamma", 1, to: deck, ctx)
        let main = try #require(snap.others.first)
        try DeckVersionController.switchBranch(deckID: deck, to: main.id, context: ctx)
        #expect(try names(deck, container) == ["Alpha": 1, "Plains": 10], "Main as it was last saved")
        snap = try #require(try await store.versions(deckID: deck))
        #expect(snap.current?.name == "Main" && snap.unsaved.isEmpty)
        let other = try #require(snap.others.first)
        #expect(other.name == "Budget" && other.ahead == 2 && other.behind == 0 && other.caption == "2 versions of its own")
        #expect(snap.versions[0].marks == [.fork("Budget")], "where Budget splits off")

        // And back: the unsaved Gamma is there, as an automatic version.
        try DeckVersionController.switchBranch(deckID: deck, to: budget.id, context: ctx)
        #expect(try names(deck, container) == ["Alpha": 1, "Plains": 10, "Beta": 2, "Gamma": 1])
        snap = try #require(try await store.versions(deckID: deck))
        #expect(snap.versions.map(\.title) == ["Before switching to Main", "Cheap Beta", "First"])
        #expect(snap.versions[2].marks == [.tip("Main")], "Main's newest version sits on this line")
        let against = try #require(try await store.compare(deckID: deck, from: .branch(main.id), to: .working))
        #expect(against.diff.summary == "+3" && against.fromTitle == "Main")

        // The current branch can't be deleted; another takes its own versions with it.
        #expect(throws: DeckVersionController.VersionError.self) { try DeckVersionController.deleteBranch(budget.id, context: ctx) }
        try DeckVersionController.switchBranch(deckID: deck, to: main.id, context: ctx)
        try DeckVersionController.deleteBranch(budget.id, context: ctx)
        let left = try ModelContext(container).fetch(FetchDescriptor<DeckVersion>())
        #expect(left.map(\.name) == ["First"], "Budget's two versions went with it; the shared one stays")
        #expect(try ModelContext(container).fetch(FetchDescriptor<DeckBranch>()).map(\.name) == ["Main"])
    }

    @Test func aBranchFromAnOlderVersionAndNamesAndLocks() async throws {
        let (container, deck) = try world()
        let ctx = container.mainContext
        let store = DeckStore(modelContainer: container)
        let first = try #require(try DeckVersionController.save(deckID: deck, name: "First", context: ctx))
        try add("b", "Beta", 2, to: deck, ctx)
        try DeckVersionController.save(deckID: deck, context: ctx)
        try add("c", "Gamma", 1, to: deck, ctx)

        try DeckVersionController.createBranch(deckID: deck, name: "Retry", from: first.id, context: ctx)
        #expect(try names(deck, container) == ["Alpha": 1, "Plains": 10], "the list is the version branched from")
        var snap = try #require(try await store.versions(deckID: deck))
        #expect(snap.current?.name == "Retry" && snap.versions.map(\.title) == ["First"])
        #expect(snap.others.first?.ahead == 2, "the unsaved Gamma was kept on Main")

        try DeckVersionController.renameVersion(first.id, to: "Baseline", context: ctx)
        try DeckVersionController.renameBranch(try #require(snap.current).id, to: "Second Try", context: ctx)
        snap = try #require(try await store.versions(deckID: deck))
        #expect(snap.versions[0].title == "Baseline" && snap.current?.name == "Second Try")

        try DeckEditController.setLocked(deckID: deck, true, context: ctx)
        #expect(throws: DeckVersionController.VersionError.self) { try DeckVersionController.restore(versionID: first.id, context: ctx) }
        #expect(throws: DeckVersionController.VersionError.self) {
            try DeckVersionController.switchBranch(deckID: deck, to: try #require(snap.others.first).id, context: ctx)
        }
        try DeckEditController.setLocked(deckID: deck, false, context: ctx)

        // Backed up and restored with the deck; gone when the deck is.
        let backup = try BackupController.snapshot(in: ModelContext(container), settings: [:], appVersion: "t")
        #expect(backup.deckVersions.count == 3 && backup.deckBranches.count == 2 && backup.decks[0].currentBranchID != nil)
        let round = try AppBackup.read(try backup.zipped())
        #expect(round.deckVersions == backup.deckVersions && round.deckBranches == backup.deckBranches)
        try DeckEditController.delete(deckID: deck, context: ctx)
        #expect(try ModelContext(container).fetch(FetchDescriptor<DeckVersion>()).isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<DeckBranch>()).isEmpty)
    }

    @Test func automaticVersionsAreFoldedAwayPastTheLimit() throws {
        let (container, deck) = try world()
        let ctx = container.mainContext
        try DeckVersionController.save(deckID: deck, name: "First", context: ctx)
        for i in 0..<(DeckVersionController.automaticLimit + 6) {
            try add("b", "Beta", 1, to: deck, ctx)
            try DeckVersionController.save(deckID: deck, kind: .auto, note: "Auto \(i)", onlyIfChanged: true, context: ctx)
        }
        let all = try ModelContext(container).fetch(FetchDescriptor<DeckVersion>())
        #expect(all.filter { $0.kind == .auto }.count <= DeckVersionController.automaticLimit + 1)
        #expect(all.contains { $0.name == "First" }, "a saved version is never folded away")
        let tree = DeckVersionTree(parents: all.map { ($0.id, $0.parentID) })
        let tip = try #require(try ModelContext(container).fetch(FetchDescriptor<DeckBranch>()).first?.tipVersionID)
        #expect(tree.path(from: tip).count == all.count, "the chain is whole")
    }

    /// A built deck's cards follow its list: switching takes it apart and
    /// builds the other branch's list, with nothing left behind in the
    /// deck, every copy conserved, and both steps in History.
    @Test func changingABuiltDecksListRebuildsIt() async throws {
        let w = try DeckBuilderTests.makeWorld()
        let ctx = w.container.mainContext
        let builder = DeckBuilder.shared(for: w.container)
        let deckID = w.deck.id
        let key = w.deck.collectionKey
        let before = try DeckBuilderTests.copies(in: w.container)
        let total = before.values.reduce(0, +)
        try DeckVersionController.save(deckID: deckID, name: "Full", context: ctx)

        // A branch without Alpha (two copies, both owned). Beta is on both
        // lists and owned nowhere: missing either way.
        try DeckVersionController.createBranch(deckID: deckID, name: "Lean", context: ctx)
        let dropped = try #require(w.deck.cards.first { $0.name == "Alpha" })
        let droppedName = dropped.name
        try DeckEditController.setQuantity(deckCardID: dropped.id, 0, context: ctx)
        try DeckVersionController.save(deckID: deckID, name: "Without one", context: ctx)
        let full = try #require(try ModelContext(w.container).fetch(FetchDescriptor<DeckBranch>()).first { $0.name == "Main" })
        let lean = try #require(try ModelContext(w.container).fetch(FetchDescriptor<DeckBranch>()).first { $0.name == "Lean" })

        // Not built: only the list changes.
        let plain = try await DeckVersionController.changingList(deckID: deckID, container: w.container) {
            try DeckVersionController.switchBranch(deckID: deckID, to: full.id, context: ctx)
        }
        #expect(plain == nil)

        _ = try await builder.build(try await builder.plan(deckID: deckID, sourceCollections: nil, includeSideboard: false))
        let builtFull = try #require(try DeckBuilderTests.copies(in: w.container)[key])
        let actionsBefore = Set(try ModelContext(w.container).fetch(FetchDescriptor<AuditRecord>()).map(\.actionID)).count

        let rebuild = try #require(try await DeckVersionController.changingList(deckID: deckID, container: w.container) {
            try DeckVersionController.switchBranch(deckID: deckID, to: lean.id, context: ctx)
        })
        #expect(rebuild == DeckVersionController.Rebuild(returned: 3, built: 1, missing: 1), "\(rebuild)")
        let inDeck = try ModelContext(w.container).fetch(FetchDescriptor<CollectionEntry>()).filter { $0.collectionName == key }
        #expect(inDeck.reduce(0) { $0 + $1.quantity } == rebuild.built)
        #expect(!inDeck.contains { $0.name == droppedName }, "the card Lean doesn't list went home, not left in the deck")
        #expect(try DeckBuilderTests.copies(in: w.container).values.reduce(0, +) == total, "copies conserved")
        let records = try ModelContext(w.container).fetch(FetchDescriptor<AuditRecord>())
        #expect(Set(records.map(\.actionID)).count == actionsBefore + 2, "a disassembly and a build, each one History action")

        // And back, restoring: the full deck again.
        let fullVersion = try #require(try ModelContext(w.container).fetch(FetchDescriptor<DeckVersion>()).first { $0.name == "Full" })
        let again = try #require(try await DeckVersionController.changingList(deckID: deckID, container: w.container) {
            try DeckVersionController.restore(versionID: fullVersion.id, context: ctx)
        })
        #expect(again == DeckVersionController.Rebuild(returned: 1, built: 3, missing: 1), "what it can't supply is counted, not hidden")
        #expect(try DeckBuilderTests.copies(in: w.container)[key] == builtFull)

        // A locked deck is refused before a card moves.
        try DeckEditController.setLocked(deckID: deckID, true, context: ctx)
        await #expect(throws: DeckVersionController.VersionError.self) {
            try await DeckVersionController.changingList(deckID: deckID, container: w.container) {
                try DeckVersionController.switchBranch(deckID: deckID, to: full.id, context: ctx)
            }
        }
        #expect(try DeckBuilderTests.copies(in: w.container)[key] == builtFull, "still built")
        let state = try await builder.builtState(deckID: deckID)
        #expect(state.copies == builtFull && state.sources == ["Main"] && !state.includesSideboard)
    }
}
