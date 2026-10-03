# Deck versions, and what History is for

**Status.** Built: deck versions and branches (as named branches with a
tip, restore-as-new-version — simpler than the derived lines proposed
below; see `Models/DeckVersion.swift` and CLAUDE.md "Deck versions"),
Compare, blocked actions said in place (`LedgerReplay.blocker`), and deck
deletion as an undoable ledger action. A list change on a built deck
takes the deck apart and rebuilds it (two History actions, not the single
Rebuild action proposed below, and not optional: the cards always follow
the list). Not built: container records for collections and lists,
"stops at" on a blocked multi-step switch.

The design note as written before building follows. It answers: should decks get git-style
versions and branches; can History be the backbone; what belongs in the
History tab and what belongs to a deck; and what History should do about
actions that can no longer be undone or redone.

## What exists today

Two things change in this app, and only one of them is recorded.

| | What it is | Recorded? | Undo |
|---|---|---|---|
| **Copies** | `CollectionEntry` rows: physical cards in a collection, a list, or a built deck's hidden collection | Yes — `AuditRecord`, one signed delta per row, grouped by `actionID` | History: a tree, any number of steps, branches |
| **Deck lists** | `DeckCard` rows: what a deck *wants*, per board | No ("a list is a wish") | None |
| **Containers** | `MTGCollection`, `Deck`, `DeckFolder` rows themselves | No. A deleted collection is implied by its rows' removal records; a created one leaves no trace | Deleting a collection undoes (rows come back, the collection with them). Creating one, deleting an empty one, and everything about a deck's existence do not |

History's invariant is the valuable part: **the ledger's sum is the
collection**. Every record is a delta of copies; replay is arithmetic;
`DeckBuilderTests` asserts conservation. Anything added to the ledger has
to keep that true or History stops being trustworthy.

## Why deck versions are not History

They look alike (both are "undo with branches") but they differ in every
property that shaped History's design:

1. **What changes.** History moves copies, and copies are conserved. A
   deck list is free text with counts: adding a card to a list creates
   nothing and takes nothing. There is no delta to sum.
2. **Scope.** History is global and its order matters across
   collections: an action is recorded against the state its parent left.
   Deck versions are per deck and independent. Two decks' edits never
   conflict, so interleaving them in one tree would make "undo" jump
   between unrelated decks — and undoing a collection change would have
   to step back through list edits that have nothing to do with it.
3. **Granularity.** A History action is one user gesture (an import, a
   build). A deck is edited in bursts of dozens of +/− taps; one ledger
   action per tap would bury the History tab, and nobody wants to undo
   "the fourth tap". What a deck wants is *named points*: "before I cut
   the dragons", "budget build", "after Friday's games".
4. **Replay.** Undoing a copy move can fail (the copies are gone). A
   list restore can never fail: it is replacing rows with rows.
5. **What the user asks.** History answers "what happened to my cards,
   and can I take it back?". Deck versions answer "what did this deck
   look like, what did I change, and what if I tried it another way?".

So: **a separate feature, scoped to the deck, borrowing History's model
and UI rather than its storage.**

## What can be shared

The parts of History that are not about copies are reusable as they are:

- **`HistoryTimeline`** is pure: steps in, a tree out (parent, children,
  head, `lastVisit`, `lines()`, `jumpPath`). It knows nothing of
  `AuditRecord`. A deck's versions are the same shape: nodes with a
  parent, a head, branches named at their tip. It can be used directly,
  or reduced — a deck's tree does not need to be *derived* from
  undo/redo records, because a version stores its parent.
- **The branch list UI**: `HistoryRail`, a section per line, Switch,
  Rename, the junction row, and the window that cuts a long list
  (`HistoryWindow`). Generalise the row from `HistoryAction` to a small
  protocol (title, detail, date, state) and both screens draw with it.
- **`HistoryBranchName`'s rule** — a name lives on a line's tip and
  follows the work — carries over unchanged.

## Proposed design

### Model

```swift
@Model final class DeckVersion {
    @Attribute(.unique) var id: UUID
    var deckID: UUID
    var parentID: UUID?        // nil for a deck's first version
    var createdAt: Date
    var name: String?          // "Budget", "Before cutting dragons"
    var kindRaw: String        // "saved" | "auto"
    var listJSON: Data         // [DeckVersionRow]: board, qty, scryfallID, oracleID, name
    var summary: String        // "+3 −2 · 100 cards", computed at save
}
```

plus `Deck.headVersionID: UUID?`. A whole-list snapshot per version, not
a diff: a list is ~100 rows (a few KB), a diff chain is a second thing
to keep right, and any two snapshots diff trivially by oracle id. Stored
as JSON for the same reason `SavedSearch` is — the row shape can grow
without a migration. Included in `AppBackup` (one more table).

### Semantics

- **The working list is not a version.** `DeckCard` rows stay the live,
  editable list, exactly as now. A version is a snapshot taken from it.
- **Save Version** (deck "…" menu, and a button on the Versions screen):
  snapshot the list, parent = head, head = new version. Optional name.
- **Automatic versions**, so there is something to go back to without
  the user planning ahead — at moments, not per tap:
  - before an import replaces or merges into the list;
  - before a restore or a branch switch (if the list has unsaved edits);
  - when a deck is built (the list as built is the one worth keeping);
  - when applying Suggested Swaps in bulk.
  Automatic versions are pruned (keep the newest ~20 per deck, and any
  that have children or a name); saved ones are never pruned.
- **Restore a version** = replace the working list with its rows, set
  head to it. If the list had unsaved edits, an automatic version is
  taken first, so restore is always reversible.
- **Branches fall out of the parent pointer**, as in History: restore an
  old version, edit, save — the old version now has two children. No
  "create branch" step. A branch is named by naming its tip, shown as a
  line, and "Switch" restores the tip.
- **Unsaved edits** are shown as a dashed "Working copy · 3 changes"
  row above the head, the way History draws what is ahead of the head.
- **Compare**: any two versions (or a version and the working list) as
  a diff grouped Added / Removed / Changed count, by oracle id, with
  the stats delta (mana curve, price, the three analysis scores). This
  is the feature people actually use versions for; restore is second.

### The built layer

A deck's built copies are real cards, so they stay in History and
nowhere else. Restoring a version changes only the list; afterwards the
deck screen shows what it already shows after any list edit — some rows
built, some "in collection", some missing, and built copies the list no
longer wants. Two additions make this honest rather than confusing:

- the restore confirmation says so when the deck is built: "12 built
  cards are no longer on the list. Rebuild to return them to Main and
  pull the 9 it now needs";
- **Rebuild** = return built copies the list no longer wants, then
  build what is missing, as *one* History action. (Today that is
  disassemble + build, two actions and every copy moved twice.)

That is the whole coupling between the two features: a version restore
may *suggest* a History action; it never writes one itself.

### Where it lives

- A **Versions** row on the deck's Details page and in the "…" menu,
  pushing a screen built from History's pieces: the current line with
  the working copy on top, other branches as sections with Switch and
  Rename, a row per version (name or "Automatic · before import",
  date, summary), and its detail: the diff against its parent, with
  Restore / Compare with Current in the bottom bar.
- **Not in the History tab.** History stays the account of cards.

## What belongs where

| Event | History tab | Deck Versions |
|---|---|---|
| Add / remove / edit / move copies, import, scan | ✔ (today) | |
| Build, disassemble, rebuild | ✔ (today; rebuild new) | auto version at build |
| Edit a deck's list (+/−, board moves, swaps, import into deck) | | ✔ working copy → versions |
| Create a collection or list | ✔ **new**, see below | |
| Delete a collection or list | ✔ (today, as its rows' removal) | |
| Create / rename / move a deck or folder | | (deck's first version marks creation) |
| Delete a deck | ✔ **new**, see below | versions go with the deck, and come back with it |

## Deletion and creation as History items

Today's gaps, and the cases the user hit ("redo tries to add cards to a
deck that no longer exists"):

1. **Deleting a built deck** disassembles first (recorded) and then
   deletes the `Deck` row (not recorded). Undoing the disassembly — or
   redoing the original build — now fails with "That deck no longer
   exists": `LedgerReplay` refuses, correctly, to file copies under a
   key nobody can open. The action is in the tree but is a dead end.
2. **Deleting an empty collection** writes nothing, so it cannot be
   undone, while deleting one with a single card can.
3. **Creating** a collection or list is invisible: undo an import into
   a new collection and the empty collection stays behind.

**Recommendation: make container lifecycle a ledger action, with zero
copies.** Add `AuditAction.containerCreate` / `.containerDelete` and a
record that carries no delta (`quantityDelta == 0`, empty `scryfallID`)
plus a small payload: the container's kind (collection / list / deck),
name, and for a deck a JSON snapshot of the `Deck` row and its list
(the same `DeckVersionRow` shape — this is where the two features share
code). Deleting a deck or collection then becomes **one action**:

- delete collection = remove records for its rows + one `containerDelete`
- delete deck = disassemble records + one `containerDelete(deck, list)`

and replay learns two things: undo of `containerDelete` recreates the
container (a deck with the same id, name, format, folder and list, and
its versions un-tombstoned); undo of `containerCreate` deletes it only
if it is empty, else refuses with a reason. The invariant holds — zero
deltas sum to zero — and "Deleted Atraxa" becomes a row in History that
can be undone, which is what makes every earlier build of that deck
replayable again: undo the delete first, and the deck exists.

Because the timeline only lets an action be redone when its parent is
the head, **order alone fixes the missing-deck case**: the build can
only be redone on a path where the delete is undone, or before it
happened. The remaining failures are the legitimate ones.

(Deck versions are soft-deleted with the deck — a `deletedAt` on the
deck's versions, purged after 30 days or when the delete action is
pruned from a backup — so an undone delete brings the tree back.)

## Actions that cannot be undone or redone

Some refusals will always exist: legacy "Deck: Name" records, and copies
that are no longer where the record expects them (edited since, on
another branch). Today these are discovered by trying — an alert after
the tap, and a multi-step jump that stops halfway. Proposed:

- **Check before offering.** `LedgerReplay.canReplay(actionID:,
  direction:) -> ReplayError?` is steps 1–3 of `replay` without the
  writes (it is already structured as check-then-apply). The store
  evaluates it for the two actions that matter — next undo and each
  redo option — on every history refresh (cheap: two or three actions),
  and for a jump, for the path's first blocked step.
- **Say it in place.** A row that cannot be replayed shows a lock and
  one line ("Atraxa was deleted — undo Deleted Atraxa first" /
  "Recorded before undo existed" / "Sol Ring is no longer in Main");
  the toolbar's Undo/Redo and the detail screen's button are disabled
  with that text as their label, not enabled-then-alert.
- **Switch says how far it gets.** A branch whose path is blocked shows
  "Switch: 2 back, 3 forward — stops at Built Atraxa" before the tap.
- **A blocked branch is still history.** It stays listed (it happened);
  it is just not reachable, and says why.

## Order of work

1. `canReplay` + blocked rows in History (no schema change; fixes the
   surprise today).
2. Container lifecycle records + deck delete as one undoable action
   (new `AuditAction` cases; additive columns on `AuditRecord`).
3. `DeckVersion` + Save / Restore / automatic versions + the Versions
   screen (new table; reuses `HistoryTimeline`, the rail, the window).
4. Compare, and Rebuild as one History action.

Steps 1–2 stand alone and are worth doing even if 3–4 wait.

## Open questions

- Should every list edit autosave a version after a quiet period
  (Google Docs) instead of at moments? More history, more noise; the
  proposal above leans to moments plus an explicit Save.
- Version limit per deck, and whether automatic versions show by
  default or behind "Show automatic versions".
- Whether a version should remember the *printings* chosen (it does in
  the proposal) or only the cards — printings matter for a list that is
  also a shopping list.
