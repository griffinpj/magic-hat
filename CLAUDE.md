# magic-hat

iOS app for managing a Magic: The Gathering collection and decks. SwiftUI +
SwiftData, iOS 26 (Liquid Glass), native UI throughout.

## Commit rules

- Every commit message MUST begin with one of: `feat:`, `fix:`, `chore:`.
- Keep the subject imperative and concise.
- Do NOT add AI/Claude authorship or `Co-Authored-By` trailers.

## Build

Full Xcode is required (Command Line Tools alone can't build SwiftData/SwiftUI
macros). If `xcode-select -p` points at CommandLineTools, either switch it
(`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`) or prefix
build commands with `DEVELOPER_DIR`:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun xcodebuild build -project magic-hat.xcodeproj -scheme magic-hat \
  -sdk iphonesimulator26.0 -destination 'generic/platform=iOS Simulator'
```

The project uses file-system-synchronized groups, so new files added under
`magic-hat/` are picked up automatically — no `.pbxproj` edits needed.

## Architecture

Layered so responsibilities stay isolated. Views and controllers are kept in
separate top-level folders, each sub-sorted by feature (Collection, Decks,
History, Search, Scan, Settings, Backup). Shared layers (Models/Clients/Utils) stay flat because they
are cross-cutting, not owned by one feature.

- `App/` — app entry, `ModelContainer` schema.
- `Views/<Feature>/` — SwiftUI views only (presentation).
- `Views/Cards/` — the card UI every feature shares (grid, tile, viewer,
  detail, add/edit sheets, mana symbols). Driven by `[CardItem]`, never by
  a feature's models, so Collection and Search render the same screens.
- `Controllers/<Feature>/` — feature logic that orchestrates models + clients
  (e.g. `ImportController`, `CardHydrationController`).
- `Models/` — SwiftData `@Model` types and plain value types.
  - Structure is flat: `MTGCollection` → cards. **The collection is the
    binder.** A ManaBox file's binders exist only inside the import wizard, as
    a way to choose which rows to take; once imported, rows carry no binder
    and identical printings from different binders merge into one row.
  - `MTGCollection` — a named collection (unique name). Import targets one
    collection: a new one, or an existing one to merge into.
  - **Lists** are `MTGCollection` rows with `kind == .list` (a wishlist, a
    trade list): the same rows, grid, sheets and History, but *not owned*.
    `CollectionStore` builds `allRows` with `CardItem.inList` set and every
    owned read goes through `ownedRows` (lists left out): the overview's
    totals, All Collection, `ownedCards`, `ownedIndex`,
    `ownedScryfallIDs`. `DeckBuilder` never takes from a list or returns
    to one. A deleted list's records carry `AuditRecord.collectionKindRaw`
    = "list" so an undo brings back a list, not a collection.
  - `DeckFolder` — Files-style folders on the Decks tab (`Deck.folderID`,
    `DeckFolder.parentID`, nil at the top). Deleting a folder moves its
    contents up; `DeckFolderTree` (pure) does paths and the no-move-into-
    itself rule.
  - `CardMeta` — cached Scryfall metadata (image URLs, dims), keyed by
    Scryfall ID; one per card, shared across collections.
  - `CollectionEntry` — one owned row (collection + finish + condition +
    qty); mirrors a ManaBox CSV row minus its binder. Identity for merging is
    `CollectionEntry.mergeKey` = `scryfallID|collection|finish|condition` —
    deliberately without binder. CSV fields are denormalized so the collection
    is browsable before hydration.
  - Import modes against an existing collection: **Add** merges (matching
    rows sum quantities, including duplicates within one file); **Replace**
    clears the whole collection first. There is no per-binder replace because
    there are no binders to scope it to.
  - `AuditRecord.binderName` still exists. It is historical: the ledger is
    append-only and older records name their source binder. New records
    leave it empty; History labels actions by collection.
  - **Decks** (`Deck`, `DeckCard`) are two layers. The *list*: DeckCard
    rows per board (commander / main / side / maybe) naming a printing for
    display and an oracle id for matching. The *built* cards: CollectionEntry
    rows in the deck's hidden collection, `collectionName ==
    Deck.collectionKey` ("deck:<uuid>"), each carrying
    `sourceCollectionName`. There is no MTGCollection row for a deck, so
    the Collections tab never lists one; the store labels such rows
    "Deck: Name" wherever an owned row's collection is shown.
    Building (`DeckBuilder.plan` → `build`) takes copies for what the list
    still lacks, matching by oracle id (any printing satisfies the list),
    preferring the exact printing, then non-foils, then the largest stack:
    the source row is decremented (deleted at zero), the deck row created or
    merged by `mergeKey`, and two AuditRecords (−n source, +n "Deck: Name")
    written under one actionID. Disassembling returns every row to its
    `sourceCollectionName` (or the first collection if that one is gone),
    merging by `mergeKey`. Copies are conserved; `DeckBuilderTests` asserts
    it. Deleting a built deck disassembles first.
  - `AuditRecord` — append-only ledger. Records sharing an `actionID` come
    from one user action; each has a signed `quantityDelta` and a
    snapshot of the row it touched (`EntrySnapshot`). Backs the History
    tab and undo/redo (see History, undo and redo).
  - `ManaBoxRow` — parsed CSV row (the on-disk import schema).
- `Clients/` — API clients. Only describe endpoints + request/response
  shapes.
  - `ScryfallClient` — `/cards/:id`, batched `/cards/collection`,
    `/cards/search` (printings by oracle id; `oracleIndex` pages a search
    into oracle id → name for `is:gamechanger` and the `otag:` lists),
    `/sets/:code`. Primary source for card data, images and a single
    market price per finish.
  - `CommanderSpellbookClient` — `POST /find-my-combos` (a whole list →
    the combos in it and the ones one card short) and `GET /variants/?q=
    card:"Name"` (every combo a card is in). No key.
  - `RecommanderClient` — `POST /decks/recommend/top` (commander + list →
    the meta's picks with a 0–1 co-occurrence score, keyed by oracle id).
    Needs ten or more cards. No key.
  - `EDHRECClient` — `json.edhrec.com/pages/{cards|commanders}/<slug>.json`,
    the JSON behind EDHREC's pages rather than a published API: card lists
    with `lift` (card pages) or `synergy` (commander pages), inclusion
    counts and salt; every field optional, an unknown slug is a 403, and a
    page that fails to decode is "no EDHREC data", never an error shown.
    `slug(for:)` is EDHREC's name form. All three pace through
    `RateLimiter` (2/sec) and cache through `DiskJSONCache`.
  - `MTGJSONClient` — second provider, bulk-only (no per-card endpoint):
    `<SET>.json` per set and `AllPricesToday.json`. Its value is the full
    retail picture (low/mid/market/buylist across TCGplayer, Cardmarket,
    Card Kingdom) that Scryfall does not expose. Prices are keyed by MTGJSON
    UUID, so join via `identifiers.scryfallId` from a set file
    (`scryfallToUUID(setCode:)`). `AllPricesToday.json` is tens of MB —
    only ever fetch it from an explicit user action with progress.
- `Utils/` — cross-cutting infrastructure, no API-specific logic.
  - `HTTPClient` — transport, required headers (User-Agent/Accept), decoding.
  It never touches `URLSession.shared` at init: the first touch
  initialises CFNetwork, and dyld's lazy binding of it ran 8.8s on the
  main thread at launch when `SearchView.init` reached
  `ScryfallClient.shared`. `requestData` is `@concurrent`, so the first
  touch happens inside the first request, on the global executor —
  building and starting a request never runs on the main actor (the
  first search keystrokes used to pay CFNetwork's first-use setup). Not
  prewarmed at launch either: see the dyld note under set symbols.
  - `RateLimiter` — actor enforcing Scryfall per-endpoint limits.
  - `CSVParser` — RFC-4180-ish parser + ManaBox mapping.
  - `PrintingsCache` — "all printings of this card" by oracle id. Written to
    disk with a 7-day TTL (printings only change when a set releases), so
    cold launches don't re-run searches. The card viewer warms it for the
    card on screen, debounced, so opening the detail screen is instant.
  - `SetSymbolLoader` — see Set symbols below.
  - `ImageLoader` — card image cache: original bytes on disk (Caches/),
    decoded+downsampled UIImages in memory keyed by URL+size. Disk reads,
    decode and downsample run in `@concurrent` helpers via ImageIO, several
    at once — a `Task` made in the actor inherits it, and they used to run
    on the actor one at a time, so the viewer's large image decoded only
    after the grid's queued warm-ups. The views (`CardImageView`,
    `CardArtThumb`, `CardArtImage`) read `ImageMemoryCache` synchronously
    in their body: `.task` runs after the first frame is committed, so a
    warmed tile used to draw its placeholder first and the viewer's zoom
    grew out of a grey card. Only a card shown large (the viewer) gets a
    spinner: a `ProgressView` is a UIKit activity indicator sized through
    Auto Layout, one per unloaded tile while scrolling.
  `cached(oracleID:)` is memory only; disk is read, decoded and written
  `@concurrent` inside `printings` — it used to decode every printing of
  the card on the main actor each time the pager rested on a card, which
  for a basic land is hundreds of cards (the stalls while swiping).
- `Controllers/Collection/`
  - `ImportController` — applies a parsed import (add/replace), writes audit.
  - `CardHydrationController` — fetches card metadata (whole collection, then
    viewport top-ups) and refreshes stale prices. Bumps `revision` on every
    write so views can rebuild without a second unbounded query.

## Rate limits (Scryfall)

Enforced in `RateLimiter`, at **half** of what Scryfall publishes (about
10/sec to `api.scryfall.com`; a 429 then a network block past it), because a
phone, a simulator and a test run share one IP while developing and each
used to take the whole budget — Scryfall sent "FAILURE TO ACT WILL RESULT
IN A NETWORK BLOCK" (2026-10-03). One shared bucket for every API family
(5/sec; the families used to pace only against themselves, and search +
collection + the rest added up to 14/sec); inside it `/cards/search|named|
random|collection` 1/sec and `/bulk-data` 5/min; images
(`cards.scryfall.io`, `svgs.scryfall.io` — a CDN outside the API limit) on
their own 5/sec lane so a scroll never starves a hydration batch. **A 429
from any Scryfall host holds all Scryfall traffic** for `Retry-After` (60s
without one): `HTTPClient` calls `RateLimiter.backOff`, throws
`HTTPError.rateLimited`, and Data Activity shows the countdown; a loader
that hits it marks its chunk failed and its next chunk waits at the limiter,
so nothing retries into the block. Other hosts (Spellbook, Recommander,
EDHREC, deck sites) stay at 2/sec each. `RateLimiterTests` runs the actor
on a fake clock. All requests send an accurate `User-Agent` (`MagicHat/1.0`)
and an `Accept` header.

## Reads go through CollectionStore; writes bump the tracker

Views do **not** hold `@Query` over large tables (entries, card metadata).
That fetch runs synchronously on the main thread during the view's first
render — which is exactly when a navigation push is trying to animate, and
on the Collections tab it meant loading the whole store to draw the home
screen. Instead:

- `CollectionStore` (a `@ModelActor`) does the fetch + map + sort on a
  background context and returns Sendable values: `CollectionSnapshot`
  (items plus the ids still pending metadata and the ids with stale prices),
  `[CollectionSummary]`, `ownedScryfallIDs()`. The view shows a placeholder
  and fills in.
- Every write path (import, delete, later deck moves) calls
  `CollectionChangeTracker.shared.bump()` once when done. Views key a
  `.task(id: tracker.revision)` on it to refetch.
- The store caches snapshots per "collection|sort" under a `StoreStamp`
  (change revision + hydration revision, read on the main actor and passed
  in). The Collections tab asks `overview(stamp:)` for the totals first —
  cheap, and they are what the tab draws — then `prewarmSnapshots(sort:
  stamp:)` builds every collection's snapshot, and All Collection's, so
  the first tap into a collection is a lookup instead of a second full
  fetch queued behind the first. Until the totals land the tab shows a
  loading card and redacted counts, not empty cards. A caller whose stamp
  moved on gets a fresh fetch; a call without a stamp (tests) is always
  fresh. Measured on the real export with the 100ms watchdog
  (`RealCollectionTests`): launch and the first push into the collection
  record no app-side stall; the two records are XCUITest's own
  (accessibility bundle load, its os_log).
- **One read of the rows per stamp.** `CollectionStore.allRows(stamp:)`
  builds every owned row as a `CardItem` (with its pending/stale flags)
  once and caches it; the overview, every snapshot, All Collection,
  `ownedCards(stamp:)` (a deck's add sheet and its analysis),
  `ownedIndex(stamp:)` (what DeckStore counts as owned/available) and
  `ownedScryfallIDs(stamp:)` all come from it. Building it is the cost of
  any read — the first property read on each CardMeta fires its fault and
  decodes the whole model — and the tab used to pay it three times per
  stamp (a backfill names pass, the totals, the prewarm), then every deck
  tile, deck screen, analysis and synergy lookup paid it again on
  DeckStore's queue (Time Profiler, real export, debug: Decks tab 530ms →
  36ms, opening a deck 550ms → 15ms, the analysis's candidates 600ms →
  16ms). The overview carries `entryCollectionNames`, which the tab
  backfills MTGCollection rows from.
- The tab shows the **last overview** (`LastOverview`: a few KB in
  UserDefaults, per store, never for seeded UI-test stores) in its first
  frame — read synchronously as the view's initial state, not through an
  async file read, which under a debugger waited seconds behind the
  launch's library loads — then replaces it with the fresh one. The totals
  used to take ~0.6s after the first frame on the real collection, and
  "Adding up your collection…" only shows on the very first run. It **skips its refresh while a
  collection is pushed** on top and runs once on the way back: during a
  sync each pass re-read every row on the store's queue, the queue the
  pushed grid's own refreshes wait on.
- SwiftData, measured on the real export (debug, simulator, on-disk
  store): a `propertiesToFetch` fetch is *slower* than a plain one
  (87 vs 60ms for 3.8k entries, 126 vs 90ms for 3.5k metas) — each
  partial row is faulted in as it is read — and reading `entry.card` is
  the expensive part of a row (330ms without prefetch, 410ms *with*
  `relationshipKeyPathsForPrefetching`; a separate CardMeta fetch by
  `ids.contains` joined in a dictionary is 90ms). Reads keep the
  relationship because DeckBuilder matches copies through it; share the
  rows rather than adding passes.
- `LaunchPrewarm` runs from `RootView`: the Mana and Keyrune fonts are
  parsed off-main (the first pip drawn used to parse the file on the main
  thread, 0.79s); an invisible field with an empty inputView loads the
  text-input stack two seconds after the first frame so the first search
  tap only has to show the keys — two seconds, not 0.6, because it is the
  one deliberate main-thread cost at launch and it used to land under the
  Collections tab's first fill (the foil warm-up follows it at 2.6s so the
  two never stack) — skipped when a debugger is attached (see
  "Measuring on a device" below); every SF Symbol the app draws (`symbolNames`,
  checked against the source by `LaunchPrewarmTests` — every literal on a
  symbol line, ternaries and `.symbolVariant` forms included, after
  "lock" in the deck menu cost 0.22s opening a deck; and no `""` names,
  which are looked up and fail like any other; and every name a real
  symbol, since a missing one draws nothing and logs a SwiftUI fault per
  draw — "bookmark.badge.plus" did) is resolved on a
  background queue, because the first lookup of a name in CoreUI's
  catalog is disk-bound — 0.44s on the first tap of the Search tab, two
  0.3s stalls opening a deck; and the foil sheen's Metal pipeline is
  compiled (`Shader.compile`) and then drawn once by a 1pt
  `FoilWarmupView` ~2.6s after launch, since RenderBox builds a specialised
  pipeline on the main thread at the first real draw (0.47s under the
  first push into the collection) — `FoilSheen` draws nothing until
  `FoilWarmup.isReady`, and removed after a frame so nothing keeps
  running. The SF Symbol prewarm runs four seconds after launch. A
  hidden `CardViewerView` to warm its view types was tried and removed:
  it built a real navigation bar, toolbar and haptics engine behind the
  tabs — 9.8s on a device, with Auto Layout complaining about a 106pt
  bar in a 90pt container.
- Hydration bumps `CardHydrationController.revision` per 75-card batch;
  views refetch on a **debounce** (longer while a sync is running) and merge
  in place without reordering, so the grid doesn't reshuffle mid-sync.
  Screens observe it through `HydrationObserver` in a `.background`, not
  an `onChange` in their own body: reading the revision there re-rendered
  the screen — the collection grid, the Collections tab and the import
  sheet it presents (whose init regrouped all 3.9k parsed rows) — on
  every batch. The grid's "Syncing n/N" pill is its own view for the same
  reason. The wizard's binder counts are worked out with the parse,
  off-main.
- Small tables (`MTGCollection`, `SavedSearch`, per-oracle rulings) are
  fine as `@Query`. The audit ledger is not small: History reads it through
  `CollectionStore.history()`. A `@Query` re-runs on the main thread after
  *every* save on any context — with `CardMetaWriter` saving a batch every
  half second during a sync, a ledger query meant a main-thread refetch of
  thousands of rows per batch.

For this to compile, the `@Model` classes, `CardItem` (and its extensions),
and the enums they use are all `nonisolated` — opted out of the project's
default MainActor isolation. Without that no data work can leave the main
thread. New model/value types must follow suit.

**A `@ModelActor` is not off-main by itself.** Its
`DefaultSerialModelExecutor` runs each job on whatever thread awaited it:
called from a view, `CollectionStore.snapshot` fetched, mapped and sorted
on the main thread (measured with `HangDetector`: 0.47s stalls in the
sort and in CoreData SQL generation while pushing into a 4k-card
collection during a catalog ingest), and only `CardMetaWriter` was ever
off-main because the ingest calls it from a detached task. So the four
actors (`CollectionStore`, `CardMetaWriter`, `DeckStore`, `DeckBuilder`)
conform to `ModelActor` by hand and use a `DispatchSerialQueue` as
`unownedExecutor` — readers at `.userInitiated`, the writer at
`.utility`. `testEnteringCollectionIsFastDuringCatalogIngest` keeps the
push measured under a real on-disk store (`UITEST_DISK_STORE`), a 4k
seed (`UITEST_SEED_COUNT`) and a looping ingest of the bulk slice
(`UITEST_INGEST_FILE`). Any new ModelActor must do the same.

## Big card lists are never a view input as an array

SwiftUI decides whether a view needs updating by comparing its inputs,
element by element for arrays — and it materialises a `ForEach`'s data
and compares that too. With the real collection (3,900 `CardItem`s, ~40
fields each) that comparison ran 0.86–1.14s on the main thread, once per
hydration batch, per sort and per push into the collection (HangDetector:
`AGDispatchEquatable → Array.== → CardItem.==`). So:

- `CardItemList` is the view-facing shape of a card list: Equatable by a
  stamp taken at construction (one integer compare), with `ids` (a plain
  `[String]`, cheap to compare) and `item(for:)` / `index(of:)` lookups.
  `CardGridView`, `CardViewerView`, `CardViewerSession` and
  `SearchController.resultList` take it; the grid, the pager and the
  deck add sheet's Lists iterate `ForEach(list.ids, id: \.self)` and
  fetch each card by id. Hold a list in state and assign a new one when
  the cards change; never build one inside a body, and never hand a
  `ForEach` or `List` thousands of card values.
- A `@State` array of cards is just as bad: the current value is copied
  into the view value and the *parent* compares it card by card on each
  of its own updates (1.68s during a mid-sync sort). `CollectionCardsView`
  and `DeckAddCardsView` hold `CardItemList`s, never `[CardItem]`.
- Sorting and the hydration merge in `CollectionCardsView` run on a
  detached task; only the assignment lands on the main actor.
- The deck add sheet lists at most `browseLimit` (400) owned cards when
  nothing is typed, with a footer saying the rest are a search away: a
  List of 3,800 rows costs SwiftUI a third of a second to rebuild its
  identity list on every update.
- Per-row menus use `ForEach(…, id: \.rawValue)`: the Identifiable
  default `\.id` is a generic key path re-instantiated per row, resolving
  generic arguments by mangled name — 0.25s over the first rows of a
  debug build. Deck rows draw one detail line rather than a `ViewThatFits`
  over two, which built both trees per row.
- What is left, measured on the real collection with a 100ms bar
  (debug build, XCUITest attached): the system Paste button's
  synchronous XPC on the import sheet (0.3s), UIKit instantiating the
  search Form's switches on the first tap of the tab (0.2s), UIKit trait
  propagation when the viewer is presented (0.14s), and a 0.12s
  residual of the foil pipeline's specialisation on the first grid draw.
  None has an app frame in its stack.
- `CardHydrationController.hydrate(scryfallIDs:)` tests membership over
  the window rather than `subtract`ing the whole hydrated set (0.12s per
  tile appearing with 3,900 ids hydrated).

## Keep work off the main thread

Responsiveness is a hard requirement: the UI must never lag or freeze. Any
non-trivial work — file I/O, parsing, decoding, networking, image processing,
bulk data writes — belongs off the main thread.

- Put pure, CPU-bound work (CSV parsing, decoding) on a background task
  (`Task.detached(priority: .userInitiated)`), then hop back to update state.
- Mark pure value types / helpers `nonisolated` so they don't inherit the
  project's default MainActor isolation and can run off-main without warnings
  (e.g. `ManaBoxRow`, `CardFinish`, `CSVParser`, `HTTPClient`).
- Networking runs off-main via `nonisolated` clients + `RateLimiter` (an
  actor); never block on the main thread waiting for a request.
- The same holds for a controller's `nonisolated static … async` helpers
  called from a main-actor task: without `@concurrent` they run on the
  main actor. `DeckAnalysisController.candidates` (a loop over every
  spare card), `fetchCombos`/`fetchMeta`, `EDHRECSynergyLoader.picks` and
  `CardSynergyController`'s loaders are `@concurrent`.
- **Approachable concurrency is on** (`SWIFT_APPROACHABLE_CONCURRENCY`), so
  a `nonisolated async` function runs on the *caller's* actor, and the
  clients are called from the main actor. CPU work inside them must opt out
  explicitly: `HTTPClient` decodes JSON in a `@concurrent` function. Before
  that, every search page, catalog and hydration batch was parsed on the
  main thread — under the keyboard during live search.
- Bulk SwiftData writes go through `CardMetaWriter`, a `ModelActor` with
  its own background context: hydration batches, the catalog ingest,
  rulings, the hydration "what's still needed" lookup, and the ManaBox
  import (`ImportController.apply` hands the rows to
  `CardMetaWriter.runImport`; progress hops to the main actor ~100 times).
  A 75-card save on the main context was enough to stall the keyboard, the
  catalog ingest ran for minutes, and a 3,900-row import on the main
  context left every row registered there, taxing every background save
  that followed. Only small user-initiated writes (add/edit/remove, deck
  list edits) stay on the main context. A *bulk* add is not small: Add
  from a selection, the scan tray and a list import go through
  `CollectionEditController.addMany` / `DeckEditController.addMany`,
  which run on the writer (`runAddMany`, `runDeckAddMany`) with the
  metas and existing rows fetched by `IN` queries of 500 and one save.
  Adding 3,800 selected cards per row on the main context froze the app
  for 27.6s on the real export. The main actor learns of
  background writes through `CardHydrationController.revision` and
  `CollectionChangeTracker`, never by observing the models.
- Long-running user actions should show progress and keep the UI interactive
  (or explicitly disable only the controls that must not change mid-operation).

## Reusable card UI

Card browsing is built from generic, source-agnostic components in
`Views/Cards/` (they take plain values, not SwiftData/Scryfall models).
Collection and Search both use them; a search hit gets the same tile, viewer,
detail screen and actions as an owned card:

- `CardItem` (Models/) — presentation value type for one card. Build it from
  `CollectionEntry`+`CardMeta` (owned) or, later, from a `ScryfallCard`
  (search). Carries `owned` so non-owned results can dim.
- `CardGridView` — 3-wide grid of `[CardItem]`; `onAppearIndex` lets the
  parent hydrate/prefetch. Tap → zoom into `CardViewerView`.
- `CardViewerView` — full-screen viewer presented with `fullScreenCover` +
  `navigationTransition(.zoom)` from the tile (`matchedTransitionSource`),
  the Photos pattern. Horizontal pager that peeks neighbours; swipe flows
  through the grid. Info panel below; actions in a native `.bottomBar`
  toolbar; the detail screen is *pushed* inside the viewer's own
  `NavigationStack`, so popping it lands on the same card. Dismiss: close
  button, or the zoom transition's own drag/pinch.
  The grid keeps its `ScrollViewReader` scrolled to the card the viewer is
  on (via the `currentID` binding), so the zoom-out lands on the right tile
  and the grid is where the user left off.
  It is not a ZStack overlay, and shouldn't become one: an overlay drawn
  inside the pushed screen sits *below* the navigation and tab bars (Back
  and the tab pill stay live through the dim), gives VoiceOver no way out,
  and can't use the toolbar API.
- `CardDetailView` — in the order the questions come: the art as a hero
  with the name, cost, type, P/T and the printing it was opened on (set ·
  number · rarity · artist) over its foot; the rules text as a card; one
  scrolling row of chips (mana value, the formats it is legal in, EDHREC
  rank); then Printings | Rulings as a segmented control. The navigation
  title is empty while the hero shows (white text over busy art read
  badly) and appears once it has scrolled away (`onScrollGeometryChange`).
  Printings are grouped by set, newest set first, each set a rounded
  container drawn row by row (`RowPosition` rounds the right corners, so
  the LazyVStack stays flat and lazy) with the set's code and year in its
  header; a row shows its number, its treatment ("Borderless",
  "Showcase", "Extended Art" … from `ScryfallCard.treatment`, out of
  `frame_effects` / `border_color` / `full_art` / `promo_types`), the
  prices of the finishes it comes in, "Viewing" on the one opened, and
  when owned the copies and how many are foil (`ownedItems` by the ids on
  screen). An Owned chip filters to owned printings; the field filters
  sets; a line says "4 printings in 2 sets · from $0.06". Mapping the
  printings to cards and filtering/grouping them (per keystroke) run on a
  detached task — a basic land has hundreds.
- Present the viewer with `.fullScreenCover(item:)` over a
  `CardViewerSession` — the items, the current id and any deck target
  travel *in the item*. Reading them from the presenter's other `@State`
  gave a blank viewer from a deck's search results: inside an active
  search session the presentation closure was evaluated against a copy
  of the presenter whose state was still at its initial values. The item
  is the one thing SwiftUI hands the closure fresh.
- Owned vs not: `CardItem.isEntry` (an owned row with a quantity) vs
  `CardItem.owned` (a search hit/printing we hold somewhere). The tile is
  the card in a Liquid Glass cell that underlaps it — a few points of
  margin, corners concentric with the card's — and carries on below it
  with one line: the set symbol in its rarity's colour (a set neither
  Keyrune nor the bundled icons draw shows its code — no WebKit from the
  grid), "#123", then the price (a gradient ✦ first for foil/etched; green
  above the price paid, red below; `PriceFormat.tile`, whole units from
  $10 so the line fits a third of a phone) and "×2" only when more than
  one (a green check for an owned hit). The number and count never
  truncate; the price scales first. The viewer's price line has the
  change as a ▲/▼ % chip and the amount, with the added date moved up
  to the name row. The zoom's source is the image, not the cell
  (`CardTile(zoom:)`). The glass cell passed `testGridScrollDoesNotHitch`.
  No dimming, so results look like the
  collection. Edit/Remove need an entry; a hit's rows are edited from the
  Add sheet's owned list.

Pricing: Scryfall provides only a single market price per finish
(`prices.usd` / `usd_foil`) — that is what we show (no LOW/MID tiers).

Why LOW/MID is not available yet, measured rather than assumed:

- **MTGJSON has no tiers.** Verified against `AllPricesToday`: the shape is
  `paper.<vendor>.{retail|buylist}.{normal|foil|etched}.<date> = one float`.
  One retail and one buylist number per vendor — no low/mid/market.
- **It cannot be parsed on device anyway.** 5.2MB gzipped, 53MB decoded,
  ~660MB peak RSS to parse. iOS would terminate the app. There is no per-set
  or per-card price file, so it is all-or-nothing.
- **The identifier join is affordable but moot.** Per-set files are ~1.1MB
  gzipped and immutable once a set ships, so `scryfallId -> uuid` is cheap
  per set; the blocker is the price file, not the mapping. (The MTGJSON uuid
  is a v5 UUID but is not reproducible from Scryfall fields by concatenation,
  and relying on an undocumented hash recipe would be brittle regardless.)

So LOW/MID/MARKET comes from **TCGplayer's own API**, joined via
`CardMeta.tcgplayerID`, which Scryfall hands us free in the batch call we
already make — one request, no bulk download, no UUID mapping.

TCGplayer no longer issues public API keys, so those tiers are unavailable to
us at any price. We show the single Scryfall market price and nothing else.

### Scryfall bulk data

Scryfall now publishes bulk **only as `jsonl_download_uri`** (`.jsonl.gz`) —
line-delimited, so unlike MTGJSON's single giant object it can be streamed and
parsed a line at a time at constant memory. That makes an on-device catalog
feasible. Measured: `oracle_cards` 24.7MB gz (~35k unique cards),
`default_cards` 78.8MB gz (~112k printings), `rulings` 5.4MB.

Card lines carry `image_uris` as **URLs**, never image bytes, so a catalog
download does not affect image storage — images keep streaming lazily into the
existing disk cache. Lines also carry `prices`, so a catalog refresh doubles
as a price refresh.

Implemented by `CatalogSyncController`, which ingests `default_cards` (every
English printing) and `rulings` (always — it is small and it makes the detail
screen's Rulings tab work offline):

1. `GET /bulk-data`; each dataset's `updated_at` is compared with the stored
   value, so nothing downloads unless it actually changed.
2. A **background `URLSession`** (`com.griffin.magic-hat.bulk`): the
   transfer belongs to the system, survives the app being suspended or
   dropped, and a finished file comes back through
   `AppDelegate.application(_:handleEventsForBackgroundURLSession:)` if
   the app was relaunched for it. The delegate moves the file to
   `Caches/bulk-pending/<dataset>.jsonl.gz` synchronously (the system's
   temp location dies with the callback) and resumes whoever is awaiting
   it; with nobody waiting the file is ingested on the next foreground
   (`resumeIfNeeded`) or launch. Progress is reported at most once per
   half a percent — the delegate fires per chunk, thousands of times, and
   each report is a main-actor hop that re-renders the setup screen or the
   bar. Expensive/constrained access is refused per request, so a ~79MB
   catalog waits for Wi-Fi rather than spending cellular. A relaunch
   mid-download reattaches to the running task instead of starting over.
   **When:** the first launch downloads and ingests in the foreground,
   attended. Once a catalog exists, a newer build is never fetched at
   launch: `syncIfNeeded` schedules a `BGProcessingTask`
   (`com.griffin.magic-hat.catalog-refresh`, network + external power) and
   the system runs `runRefresh` when the phone is charging on Wi-Fi. That
   is the case BGTaskScheduler exists for; hydration stays attended and
   out of it. The identifiers live in `magic-hat/Info.plist`
   (`INFOPLIST_FILE`, merged with the generated keys; the synchronized
   folder has a membership exception so it isn't also copied as a
   resource).
3. `GzipLineReader` pulls the file a line at a time. It is hand-rolled because
   Foundation only gunzips when the server sends `Content-Encoding: gzip`
   (these are files whose content is gzip), and Compression speaks raw DEFLATE,
   so the gzip header is parsed and skipped by hand.
4. Parsing runs on a detached task; each decoded batch is awaited onto the main
   actor to be written. SwiftData models are main-actor-bound here, so this
   keeps JSON off the main thread while writes stay where they must be — and
   awaiting each batch throttles the reader, so memory stays flat.

`RootView` also calls `resumeIfNeeded` when the scene becomes active: a
pending file is ingested, and the manifest is re-checked if the last look
was over an hour ago. Stray `.jsonl.gz` files in tmp (earlier builds
downloaded there) are swept at launch.

`CatalogSyncBar` narrates it above whichever tab is showing. Two things that
matter for scrolling: the bar observes the controller itself (reading `phase`
from `MainTabView` would re-render every tab on each batch), and ingest
progress is reported once per ~10 batches rather than per batch. Its
show/hide animation is attached inside the bar's own body: as an
`.animation(value: phase…)` in `catalogSyncBar()` it was evaluated in the
`safeAreaBar` closure — which runs in MainTabView's body — and did exactly
that.

MTGJSON **set files carry no prices** (verified) — only `identifiers`,
`legalities`, `foreignData`, `purchaseUrls` and similar. Prices live solely in
the bulk price files, so pricing cannot be fetched per set during import.

### What MTGJSON IS good for on device

Its bulk *price* and *card* files are too big (above), but several artifacts
are small, and some carry data Scryfall has no equivalent for. Measured:

| File | Size | Verdict |
|---|---|---|
| `Meta.json` | 113 B | Check before any larger download |
| `Keywords.json` | 4 KB | Fine |
| `CardTypes.json` | 7 KB | Fine |
| `EnumValues.json` | 19 KB | Fine |
| `DeckList.json` | 634 KB | Fine — 3,059 precons |
| `decks/<name>.json` | ~150 KB | Fine — one precon |
| `<SET>.json.gz` | ~1.1 MB | Fine per set, immutable once shipped |
| `SetList.json` | 11.6 MB | Use Scryfall `/sets` (623 KB) instead |
| `AllPricesToday.json` | 53 MB / 660 MB RSS | Server only |
| `AtomicCards.json.gz` | 52 MB | Server only |

**Preconstructed decks are the clear win** — Scryfall has no deck data at all,
and every deck card carries `identifiers.scryfallId`, so a precon joins
directly to the cards we already store ("which of these do I own?").

Per-set files additionally carry things Scryfall does not: `foreignData`
(bundled translations — relevant because ManaBox exports a Language column),
`leadershipSkills` (can this be a commander?), `edhrecSaltiness`, and
`variations`. All at 1.1 MB per set, cached permanently.

Buylist pricing (what a shop pays you) remains MTGJSON-only and remains
server-side-only, because it lives in the 53 MB price file. The
overlay shows the gain/loss vs the price paid at import (`CollectionEntry
.purchasePrice`) as `(±$Δ, ±%)`.

Set symbols: Scryfall serves set icons as SVG only, and SwiftUI cannot decode
a remote SVG. `SetSymbolLoader` rasterizes it once via a WKWebView snapshot,
caches it, and `SetSymbolView` renders it as a `.template` tinted `.primary`
so it adapts to light/dark. Given a `rarity:` the symbol takes that
rarity's colour as printed on the card (`RarityPalette`, Keyrune's
palette: uncommon silver, rare gold, mythic bronze-orange, special
purple); common keeps the tint. Pass it wherever a card is known.
The web view is created only when a symbol actually has to be
rasterized — after the PNG cache missed. It used to be warmed on every
`symbol(setCode:)` call, so each launch's first card from such a set
loaded ScreenTime and built a web view for a symbol already on disk
(measured on a device under the debugger: 3.1s on dyld's lock plus 3.3s
in `WKWebView.init`, taps queuing behind the viewer).
The web view is created at launch, never on demand: the first WKWebView
makes WebKit soft-link ScreenTime, and dyld runs that load on the calling
thread with synchronous XPC inside — 4.0s on the main thread when the
viewer showed a set the font lacks (four of 204 in a real collection).
The first symbol that needs it loads ScreenTime on a background thread
(`LaunchPrewarm.loadScreenTime`), then the web view is created on the
main actor; jobs queue until then, and the placeholder is the set code
as a badge, which is also what a set the rasterizer can't draw keeps.
Never at launch: a background `dlopen` holds dyld's loader lock, and the
main thread's own framework loads (keyboard, haptics, CFNetwork) queued
behind it — 4.5s in the keyboard prewarm on a device. Two non-obvious constraints: WebKit only paints a
web view that is **in a window**, and `takeSnapshot` captures the view at its
own alpha — so the render host is a real `UIWindow` layered *behind* the app
(`windowLevel = .normal - 1`) at **full alpha**. Rendering it faded produced a
near-transparent image that, as a template, was invisible.

## First launch and catalog refreshes

Two different surfaces for the same sync, because they're different moments:

- **First launch** — `RootView` shows `CatalogSetupView` *instead of* the
  tabs until `default_cards` has been ingested once. Blocking by default
  (the app is far more useful with the catalog) but escapable: "Continue in
  background" hands off to the bar. This is the pattern of apps that need a
  one-time asset pull (games, dictionary/reference apps): a single explained
  screen with real progress, never a spinner with no words.
- **Later refreshes** — `CatalogSyncBar`, a glass pill just above the
  tab bar in every tab's bottom `safeAreaBar` (`.catalogSyncBar()` on
  each tab root), never over the top of the screen where it covered
  titles and buttons. Not `tabViewBottomAccessory`: that slot is for a
  control that stays (Music's mini-player) and kept showing the last
  status line after the sync went idle — `SyncBarTour` drives a fake sync
  (`-uitest-fake-sync`) and checks the bar comes and goes. Non-modal; the
  app stays usable on the data it has.

Network: the catalog refuses metered paths unless the user opts in. That is
made *visible* — `.waitingForWiFi` phase, "Use cellular data (80 MB)" button
— because `waitsForConnectivity` alone left the bar at 0% forever with no
explanation. Rulings (~5MB) are allowed anywhere. `NetworkMonitor` wraps
`NWPathMonitor`.

Refresh policy (`DataPolicy`): a newer bulk build is taken only if our copy
is older than 7 days (catalog and rulings alike). Scryfall rebuilds both
daily; 79MB a day is not worth it, and a daily rulings re-ingest meant
~170k SQLite rows written on the first launch of every day — right when the
user starts typing, and the first keyboard presentation reads its resources
from the same disk. The ingest also runs at `.background` priority so the
system throttles its I/O. Owned-card prices already refresh every 6h
through the cheap batched call.

### Measuring on a device

Instruments can't record on the iOS 27 phone with Xcode 26
("An unknown problem is preventing this device from recording"), so the
device is measured with HangDetector through the console:

```
xcrun devicectl device process launch --device <coredevice id> --terminate-existing \
  --console -e '{"UITEST_HANG_THRESHOLD":"0.2"}' com.griffin.magic-hat
```

Reproduce under a debugger (what Xcode's Run does) by attaching LLDB at
launch — `device select <udid>`, `device process attach -w -n magic-hat`,
then `process continue` once it stops. **The same build behaves very
differently with a debugger attached.** Without one: cached totals in
0.1s, fresh overview 0.35s, no main-thread stall ≥0.2s through launch,
a collection, the viewer and a deck. With one, every library the process
loads stops *every thread* while LLDB handles it — over Wi-Fi debugging
(`transportType: localNetwork`) each of those costs a network round trip.
The keyboard prewarm's chain of soft-linked frameworks froze the app for
8.6s two seconds after launch (0.1s without), the store's 0.3s overview
took 6s because its thread was stopped too, and the first frames' own
system loads (Markdown for `Text` localization, HDR colour conversion)
cost ~2s. So: judge performance with the scheme's "Debug executable"
off or with the phone on a cable, and keep lazy framework loads off
launch and off first opens (`LaunchPrewarm.isBeingDebugged` skips the
keyboard prewarm; WebKit loads only for a symbol never drawn before).

Debug builds start `HangDetector` at launch: a watchdog that samples the
main thread's stack when it stops answering for 0.4s and logs it (subsystem
`magic-hat`, category `hang`, also printed). A long hang is sampled
again every half second (up to 16 samples), so a multi-second freeze
shows what it spent its time on. It pings at half the
threshold: with a fixed quarter-second gap a stall shorter than that was
only seen if it overlapped a ping. `UITEST_HANG_THRESHOLD`
lowers the bar and `UITEST_HANG_LOG=<path>` appends each report as a JSON
line, which is how `RealCollectionTests` fails a flow on any stall. It samples with Mach thread
APIs (suspend, read registers, walk frame pointers, resume), **not a
signal**: lldb stops the process on a signal, and a launch-time stall trips
the threshold on every run, so a signal-based sampler froze the app at
launch under the debugger. When something stalls on a
device, run from Xcode, reproduce, and filter the console for
`MAIN THREAD HANG` — the stack says what the main thread was doing. The
`-uitest-hang` launch argument blocks the main thread once, two seconds
after the root appears, to prove the report path; on the simulator use
`xcrun simctl spawn <udid> log show --last 10m --predicate 'subsystem == "magic-hat"'`
(the device must be booted). Measured on the simulator with the seed: the
only stalls are at launch — 0.87s creating the root hosting controller,
0.6s in a system XPC teardown — and none during a search-field tap.

## Search

The Search tab (`Views/Search/`, `Controllers/Search/`) runs on **Scryfall's
search API**, not the local catalog. Its syntax covers every filter one to
one (colour maths `c>=rg c<=3`, `legal:`, `usd`, `m:{2}{G}`, `is:foil`,
`a:`), it groups printings server-side (`unique:cards`), sorts (`order`,
`dir`) and pages (`next_page`). The local catalog has the rows but none of
that logic, and filtering 112k SwiftData objects in memory is the kind of
main-thread work this app avoids. Zero matches is a 404 on Scryfall; the
client turns it into an empty page.

Two states of one screen:

- **Landing (nothing searched):** the filters *are* the page — a Form with
  saved searches on top, every filter inline, a prominent Search button in
  the navigation bar (a `.bottomBar` item draws under the iOS 26 tab bar,
  and a floating button rides up over the keyboard). Edits go straight to
  the live query.
- **Results:** the shared `CardGridView`; filters move behind the toolbar
  icon, as a sheet over a *draft* (Reset / Done); an X clears the search
  and returns to the form with filters kept. Emptying the search field
  keeps the results when filters are active — they are still a search —
  and returns to the form only when nothing else is active.

**Live search:** the field's text is `@State` in the view, not bound to
`controller.query.text` — the landing Form observes the query, so a direct
binding re-diffed every section per keystroke. The text reaches the query
after a 350ms pause (`SearchController.scheduleText`), on Return, or from a
chip; the run follows if the query changed. The previous results
stay on screen while the next page loads (`isRefreshing`, a small spinner in
the header) so the grid never flashes empty between keystrokes. A generation
counter drops a page from an older run even if its request finishes late.
Name completions are the distinct names *in the results* (prefix matches
first), shown as a chip strip that scrolls as the grid's header. They obey
the active filters by construction; `/cards/autocomplete` takes only a
prefix and offered cards the filters excluded. `.searchSuggestions` would
hide the results. There is no results header (count, filter count): it was
one more thing snapping against the collapsing bar; progress shows as a
small glass pill instead.

Modular on purpose — three pieces that don't know about the tab:

- `CardSearchQuery` (Models) — every filter as one Codable value, plus
  `scryfallQuery`, `activeFilterCount` (filter *groups*, what the Filters
  button counts), `summary` (one-line description) and
  `normalizedManaCost` ("2gw" → "{2}{G}{W}"). Unit-tested against the
  syntax reference.
- `SearchController` (`@Observable`) — runs a query, holds `[CardItem]`
  results, pages as the grid nears the end (`loadMore(near:)`), maps
  Scryfall cards off-main, layers ownership on from `CollectionStore`.
  Depends on the `CardSearching` protocol so tests feed it pages.
- `SearchFilterSections` — the form sections over a `Binding<CardSearchQuery>`,
  embedded by the landing Form and by `SearchFiltersView` (the sheet). Any
  screen that owns a query can show either.

A later screen that wants search at the top composes the same three with
`.searchable` and hands results to `CardGridView`.

**No pushed pickers.** Long vocabularies are token fields: chips for what's
chosen, a field that suggests inline as you type (types with their catalog
and card-type glyph, keywords, sets with their symbol, artists), Return adds
free text. A term chip's menu flips is / is not or removes it. Formats and
rarities are button-style toggle chips (formats: the common eight, More
reveals the rest); colours are mana pips; price and stats are number fields.
Vocabularies come from `FilterVocabulary`, loaded once through
`ScryfallCatalogCache` (`/catalog/*` and `/sets`, on disk for a week) and
matched in memory, prefix first, against names folded once (case and
diacritics, off the main actor at load) with plain `hasPrefix`/`contains`
— a locale-aware `range(of:options:)` over ~10k artists ran on the main
thread per keystroke.

**Suggestions and the keyboard:** a token field's suggestions are rows
under it, so focusing one of the four (types, rules text, sets, artist)
scrolls that field to the top of the Form (the host passes its
`ScrollViewProxy` into `SearchFilterSections`), leaving the space above
the keyboard for the rows; a Form on its own scrolls a focused field only
far enough to show it, and the rows landed under the keys.

**Keyboard:** every field has a Return key labelled Done — the number
fields use `.numbersAndPunctuation` rather than a pad, which has none —
the Forms use `.scrollDismissesKeyboard(.interactively)`, and the results
grid dismisses on scroll. There is deliberately **no SwiftUI keyboard
toolbar** (`ToolbarItem(placement: .keyboard)`): it added seconds to the
first keyboard presentation on device. `testReturnDismissesNumberField`
covers the number field. The landing and collection search fields use
`.navigationBarDrawer(displayMode: .always)`; with `.automatic` a drawer
above a long scroll view starts hidden until the user pulls down.

**All Collection.** The Collections tab leads with an overview card
that *is* All Collection — `CollectionScope.allKey`, a scope the store
understands rather than an `MTGCollection` row, every owned row across
every collection and every built deck, each labelled with where it lives
— so the card opens it (a bare "All Collection" row under it used to say
nothing the card didn't). The card: cards and market value; up or down
since bought (`CollectionSummary.gainLoss`: the rows that carry a price
paid in the display currency, against what those rows are worth now); a
`ColorBar` of the whole collection (each card once: its colour, gold for
more than one, grey for none; Magic's palette deepened to read on glass);
and unique · sets · foils · in decks. Each collection card carries its
own facts beside the fan (sets, foils) and a thin colour bar along its
foot; a list says how many of its cards are already owned
(`ownedCopies`, from `CardItem.inCollection`); an empty one says what to
do instead of "0 cards · —". Headings ("Collections", "Lists") carry the
count past one. All of it comes from the one pass `summary(name:rows:)`
already makes per stamp; the new fields are optional so a `LastOverview`
saved before them still decodes. The rows are glass cards pushed through a
`NavigationStack(path:)` from plain Buttons, not `NavigationLink`s — a
link in a List draws a disclosure chevron beside the card — and the card
carries a `contentShape`, since as a Button's label only its drawn text
was tappable.
`entryCollectionNames()` skips `deck:` names so backfilling never lists a
deck's hidden collection as a collection.

**Searching a collection.** `CollectionCardsView` treats the collection as
a search that is always active: a search field and a Filters button (the
same `CardSearchQuery` and `SearchFiltersView`, `context: .collection`, which
hides the Scryfall-only options), no inline form. It is evaluated in memory
against this collection's cards by `CardSearchQuery.matches(_:)` — clause
for clause the local twin of `scryfallQuery` — off the main actor, keeping
the grid's order. For that, `CardMeta` keeps `colorsRaw`/`colorIdentityRaw`
(WUBRG letters), `artist` and `loyalty` from both the bulk ingest and the
batched hydration; a row stored before those existed has `colorsRaw == nil`
and counts as pending, so one hydration pass backfills it.

**Saved searches** are a SwiftData model (`SavedSearch`, query stored as
JSON so the filter model can grow without a migration), not UserDefaults:
a real user-managed list (rename, reorder, delete) that belongs with the
user's data and syncs with it if that ever comes. They head the landing
screen and the bookmark menu.

## Mana symbols

`Resources/mana.ttf` (Mana font, SIL OFL; `MANA-LICENSE.txt`) with
`mana-map.json` generated by `scripts/make-mana-map.py` from Mana's CSS,
registered at runtime like Keyrune. `ManaSymbol` (Models) parses `{…}`
tokens; `ManaSymbolView` draws a pip in Mana's cost palette; hybrids
(`{W/U}`, `{2/W}`, `{W/P}`) are *composed* from two half glyphs on a split
pip because the font has no single glyph for them — exactly what Mana's own
CSS does. `ManaCostView` lays out a cost; `OracleTextView` renders rules
text with pips inline (each symbol rendered once to a bitmap and
interpolated into `Text`). That bitmap is drawn with Core Graphics and
Core Text (`ManaSymbolBitmap`), not `ImageRenderer`: an ImageRenderer
image is backed by a lazily rendering RenderBox provider, and the text
layer that drew the pip waited 0.51s on it opening a detail screen. `ManaGlyphView` draws any named glyph — the map
also carries card-type and keyword-ability icons.

## Decks

Reads through `DeckStore` (a ModelActor): the tab's `overview()`, a deck's
`snapshot(deckID:)` — list rows joined with their CardMeta, the copies
built and the copies still available in collections (both by oracle id),
sections by card type, and `DeckStats` — and `resolve(_:)` for imports.
Ownership ("in collection", "owned") comes from `ownedIndex()`: the
shared store asks `CollectionStore.ownedIndex(stamp:)` with the current
stamp (one hop to the main actor for it), so it is a lookup over rows
already built; a DeckStore made on its own (tests) counts for itself.
Writes: `DeckEditController` (main context; list edits write no audit,
a list is a wish), `DeckBuilder` (background; moves copies, audits them).
`DeckChangeTracker` is bumped by list edits, both trackers by builds.
A list's rows also carry `CardItem.inCollection` — some printing of the
card is owned, in a collection or a built deck (the store marks them from
the owned rows' oracle ids): the tile shows the green check and the
viewer "In collection", as a search hit does.
A stepper or "+" shows its new count on the tap: `DeckAddSession`
updates its rows as it writes, and the deck list keeps a written count
until a snapshot dated at or after the write arrives — the re-read of
the deck queues behind the Decks tab's and the add sheet's re-reads of
the same write.

The deck screen: a segmented Cards / Stats / Details in a top
`safeAreaBar` under the title, the three as pages of a paged `TabView`
so a horizontal swipe moves between them too, a "+" that opens the
add-cards sheet, and one "…" menu for whole-deck actions. The picker is
a bar, not a view above the pages: it joins the bar region with the
navigation bar and search field, the lists scroll beneath it with the
same scroll-edge effect, and pinned headers pin under it. The page
container paints the grouped grey behind the bars on Stats and Details
and white on Cards — the pages stop at the bar, so without it the bar
strip was white over a grey Form. **Cards** is
the list: commander, mainboard by type with count and value, sideboard,
maybeboard; each row says built / in collection / missing, with a
quantity stepper (a locked deck shows ×n and edits nothing). Sections
run creatures, planeswalkers, battles, artifacts, instants, sorceries,
enchantments, lands (`DeckStats.typeOrder`), and the same floating sort
button as the grid orders the rows within each (`DeckCardSort` minus
Relevance, remembered as `deck.sort`). It is a
*plain* list so the type headers pin while scrolling — mid-scroll the
header says which group this is (Contacts, Music's Songs); inset-grouped
never pins. Rows have no swipe actions: the stepper removes, and a
trailing swipe fought the page swipe. When the deck breaks a rule of its
format (`DeckStats.violations`: over the size, outside the commander's
identity, over a copy limit, not legal — not "still short", which every
deck under construction is) the list leads with a banner row that opens
Stats' Check section; the add sheet shows the same line in its header
and answers a breaking add with the warning haptic instead of the
success one. No alert: the state is allowed and common mid-build. Copy
limits read the card's own exception text ("A deck can have up to nine
cards named Nazgûl", "any number of"), and basic lands including snow
are unlimited. Each row's name is led by its set symbol in the rarity's
colour. Its search field only *filters* the list. Adding is
`DeckAddCardsView`, a sheet (the "Add to Playlist" shape): field focused
on arrival, Filters in its bar, Done to leave; a top `safeAreaBar` under
the field (so the rows scroll beneath it with the scroll-edge effect)
holds, in two rows, the scope picker and one line of small bordered
capsule chips — "In collection", the commander's identity as its pips
alone (VoiceOver: "Within identity, …"), and the board menu trailing —
with what the deck breaks as one caption line under them. Section
headers are ordinary rows with their source trailing ("EDHREC") — not
Section headers, which a plain list pins, and each flashed its background
taking the pinned place under the bar. The bar has the list's own
background up under the navigation bar and a hairline, so rows don't read
through the chips (`scrollEdgeEffectStyle(.hard)` did that too, but
turned the bar's glass and the keyboard light in dark mode). Both scopes
stay mounted, the hidden one out of hit-testing and accessibility, and
Recommended's lists are matched and sorted off the main actor on every
input change whatever scope shows (`refreshRecommended`), so switching to
it is instant; each of its sections shows its own loading row rather than
the scope waiting behind one spinner. A floating glass sort button — the
collection grid's, in the same bottom-trailing corner — orders each
scope (`DeckCardSort`:
Relevance, Name, Mana Value, Price high/low, Rarity; per scope while the
sheet is open). Relevance is each list's own order; on Scryfall it is
EDHREC rank, most-played first; the collection is sorted before the
400-card browse limit. The scope is All Cards (Scryfall, or with
"In collection" an in-memory search of what is owned, one row per card,
everything owned listed until something is typed) or Recommended; for
commander decks the identity chip applies `id<=`; a row's context menu
adds to another board. It was a mode of the deck screen's own field before:
Filters had no natural place, the section picker had to step aside, and
Back popped the deck instead of ending the search. Row bodies
(`DeckRows`) are two lines on a landscape art crop (`CardArtThumb`, the
Scryfall art_crop — a whole card at 42pt was tall and unreadable), a
plain Button beside the +/stepper controls rather than a tap gesture
over the row (sibling buttons keep their own hit areas in a List), and
`ViewThatFits` drops the price, then truncates the type, so a long
status never pushes the row past its edges. Format legality is tagged on
each result ("Not legal"), not enforced: enforcing it hid every card
whose legality wasn't cached yet. Tapping a result opens the viewer with
a `DeckAddSession` — the sheet's board and per-card counts, one
observable shared with the viewer — so the viewer's bar is the same
−/n/+ as the row (Add until the first copy is in) and Remove is not
offered. Both list screens present the viewer with the zoom transition
from the row's art (`CardRowLead` takes the namespace), which is what
gives it the collection grid's drag-to-dismiss, and scroll the list to
the viewer's row so the zoom-out lands on it.

**Presenting from the deck screen, never from a page.** The viewer's
`fullScreenCover` and the add sheet are attached to `DeckDetailView`,
not to the Cards page: a cover on a page of the paged `TabView` stopped
presenting once a sheet had been shown while another page was selected
(the Stats row opening the add sheet), and only re-selecting the page
brought it back — reproduced six times in a row, gone with the move. The
page marks its rows as the zoom transition's source with the screen's
namespace and hands the session up (`onOpenViewer`).

**Build wizard** (`DeckBuildSheet`): choose source collections, review the
plan (what moves from where, what's missing) before anything changes,
confirm, result. Missing cards stay marked in the list; building again
moves only what's new.

**Import** (`DeckListParser` → `DeckStore.resolve` → Scryfall for the
rest, cached through `CardMetaWriter` → `DeckEditController.importLines`).
The import sheet parses the text once per change, off the main actor
(a computed `list` re-parsed it on every render, every keystroke in the
name field); the export sheet builds its text the same way per option.
The parser reads the shapes deck sites export — `// COMMANDER` headers, a
blank line ending the commander section, `1 Name (SET) 123 *F*`, `4x
Name`, Arena's About/Name block; the fixture
`KingUnderTheMountain.txt` is the contract; any other `//` or `#` line
is a comment (an export's type groups, a note), never a card. Import
comes from a file or the clipboard (deck sites copy lists there).
**Export** (`DeckExportView`, from the "…" menu and Details) is an
options sheet with a live preview: Default (`// HEADER`, what every site
reads and this app re-imports) or Arena (Commander / Deck / Sideboard,
no groups, no maybeboard), grouped by board or card type, sorted by
name / price / mana value, with or without printings, only missing
copies (a shopping list), which boards; then Share Text, Share File
(`DeckExportFile`, a `.txt` written on demand) or Copy in the bottom bar.
Language and tokens are not offered: the list holds English names and no
token rows. `DeckExportOptions` + `DeckListParser.export(_:options:)`.

## Deck versions

A deck list has its own history, separate from History (which is the
ledger of *copies*; a list is a wish, edited in bursts, restored by
replacing rows). It is git's model in a deck's words (`Models/DeckVersion`):
the list is the working tree; a **Version** (`DeckVersion`) is a commit —
the whole list as JSON, its parent, a name or a note; a **Branch**
(`DeckBranch`) is a name pointing at its newest version; `Deck
.currentBranchID` is HEAD; **Unsaved Changes** is the list against the
branch's tip. Two departures from git, both deliberate: there is no
detached HEAD — **Restore** saves a *new* version holding the old list, so
a branch only grows and nothing is orphaned — and **Switch** never
refuses: what is unsaved is saved as an automatic version on the branch
being left. New Branch carries unsaved changes along (`checkout -b`), or
starts at any version. Deleting a branch removes the versions only it
reached (`DeckVersionTree.unreachable`). Automatic versions (before a
switch, a restore or a branch; when the deck is built, if it keeps
versions) are folded away past twenty, re-parenting the child so the chain
stays whole. Lists compare by card and board, never printing
(`DeckListDiff`: added, removed, count changed, moved between boards).

**A built deck's cards follow its list.** A list-changing action on a
deck that is built — Switch, Restore, Discard, a branch from an older
version — goes through `DeckVersionController.changingList`: the deck is
taken apart, the list changes, and it is built again from the collections
it was built from (`DeckBuilder.builtState`: the rows' sources, and the
sideboard if it was built) — two History actions, Disassembled and Built,
each undoable there. Changing only the list left the old list's cards in
the deck's hidden collection with no row to show them, and Build never
sent them home. A locked deck is refused before a card moves, and a
branch name is checked first. Switch asks first on a built deck ("Switch
and Rebuild"); every confirmation says the cards will move; a pill shows
while it runs and the toast says what was built and what is missing
("On Main · rebuilt 95, 3 missing"). Saving, renaming and a branch from
the list as it stands move nothing.

Writes are `DeckVersionController` (main context, like every list edit; no
ledger records). Within one write, a list just replaced is saved from the
rows it was replaced *with*: the relationship still lists rows deleted a
line earlier until the context saves. Reads are `DeckStore.versions(deckID:)`
— branches with "2 versions of its own · 1 behind" against the current
one, the current branch's versions newest first with a tag where another
branch sits or forks — and `compare(deckID:from:to:)` (`DeckListRef`:
working, a version, the one before it, a branch), which also totals cards,
lands, value and average mana value on each side.

`DeckVersionsView` (the deck's "…" menu and Details page): Unsaved
Changes (the counts, a tap for the diff, Discard), Branches (Current, or
Switch; swipe and long-press for Rename, Compare, Delete; New Branch…),
Versions on <branch> on History's rail. Save Version… is the one
prominent button, in the bottom bar, only when there is something to
save; its alert takes an optional name. A version's page
(`DeckVersionCompareView`) is its changes against the one before, Restore
This Version in the bottom bar, Rename / New Branch from Here / Compare
with Current List in its menu. **Pushed with destination links and
`navigationDestination(item:)`, never `NavigationLink(value:)`**: the
Decks tab's stack has a typed path (`[DeckRoute]`), which drops values of
another type silently. An "i" in the bar opens `DeckVersionsGuideView`
(History's guide shape, `GuideRow`): versions, branches, then Versions and
the History tab set side by side point by point (what each keeps, scope,
when it records, going back, branches), what stays separate (list edits
are never in History; versions never move cards) and where they meet
(building, deleting the deck, backups). History's own guide points to it.
Versions travel in backups (`deck-versions.json`,
`deck-branches.json`) and with a deleted deck's History record.
`DeckVersionTests`, `DeckVersionFlowTests` (UI).

## Playtest and tokens

**Playtest** (`Models/Playtest.swift`, `Views/Decks/DeckPlaytestView`):
goldfishing, from the deck's "…" menu and its Details page, as a full
screen. `PlaytestState` is a plain value — library, hand, battlefield,
graveyard, exile, command zone; `newGame` (shuffle, draw seven),
`draw`, a London `mulligan` (seven again, then `pendingBottom` cards to
`bottom(_:)`), `nextTurn` (untap all, draw one), `toggleTap`,
`move(_:to:libraryEnd:)`, `play` — built from a `DeckSnapshot` (every
mainboard copy a `PlaytestCard`, commanders in the command zone). It
shuffles with any `RandomNumberGenerator`, so `PlaytestTests` seed one
(`SeededGenerator`, SplitMix64) and assert copies are conserved through
every move. No rules engine: it is a table that keeps count, and it
writes nothing. The screen: the battlefield on top (lands row, spells
row; tap to tap, hold for the other zones and View Card), a status line
(turn, library, untapped lands as "Mana", graveyard and exile buttons
opening a `ZoneSheet`), the hand along the bottom with the command zone
beside it (tap to play/cast; during a mulligan, tap to bottom, with a
banner counting down), and a labelled glass action bar — Draw,
Mulligan (turn one only), Next Turn — not a toolbar's icons, which read
as nothing at a table. `PlaytestFlowTests` plays a seeded game.

**Tokens** — Scryfall's `all_parts` with `component == "token"` is kept
on the maker's `CardMeta.relatedTokensRaw` (`RelatedToken`, one per
line; `metaVersion` 2 backfills it through hydration, and the bulk
ingest shares `apply`). `DeckStore.snapshot` rolls the played boards'
tokens up by kind (`DeckToken.collect`: name + type line, so a Soldier
from three cards is one row, with the first printing the catalog has an
image for — tokens are in `default_cards`) into `DeckSnapshot.tokens`,
and Details lists them ("Tokens · n": art, name, kind, "Made by X and 2
more"). `DeckTokenTests`.

**Import dry run** — `ImportPreview` (Models, pure): the selected rows'
copies, how many land as new rows and how many merge into rows the
destination already has by `mergeKey` (duplicates within the file count
once, as on import), and what Replace removes first. The wizard shows it
as "What Will Happen", recomputed on the store
(`CollectionStore.mergeKeyCopies`) as the destination, mode or binders
change; a brand-new collection merges nothing. The generic sheet shows
"Already in this collection: n" by name (`entryNames`). `UITEST_WIZARD_FILE`
opens the wizard on a file in a seeded run, since a test can't drive the
document picker. `ImportPreviewTests`, `SettingsImportTour`.

## Odds tools: Goldfish, Draw Odds, Mana Base, Find a Commander

Four tools, four modules, deliberately **not coupled** to each other or
to the deck analysis: each has its own reading of the cards (a few
patterns over type line, cost and rules text), its own pure model under
test, its own screen with an "i" (`ToolGuide` / `.toolGuide(_:)`, a
sheet of `GuideRow`s declared beside the screen) that says what the
numbers are, how they are worked out and what they leave out. The first
three are rows of the deck's Stats page ("Odds"); the fourth is on the
Decks tab's add menu.

- **Goldfish** (`Models/Goldfish.swift`, `DeckGoldfishView`): a Monte
  Carlo goldfish after Karsten — `GoldfishCard` reads what a card adds
  (units and colours as a bitmask, Signets net one, "{G} or {U}" is one
  of either), enters tapped (not "unless"), fetches a land, draws on
  cast (not a repeating trigger); `Goldfish.run` plays `config.games`
  games (5,000 default, ~1s off-main) of 8 turns: London mulligan on a
  land-count rule (2–5, twice), the land that helps most (untapped when
  something is castable, a colour the hand wants), then ramp → draw →
  commander (tax included) → biggest spell the mana can pay with its
  colours (an exact bipartite matching of pips to mana units; creatures
  wait a turn). `GoldfishResult` is per-turn shares: land drops (that
  turn, every turn so far), mana available vs spent, spells cast,
  colour-stuck (fit the count, not the colours), commander cast by,
  mulligans, kept-hand lands, dead cards at the end. Seeded (SplitMix64,
  shared with the playtest) so `GoldfishTests` get the same numbers. The
  screen shows five headline rows and two charts (land drops, mana made
  vs spent) — nothing a headline says is charted again, and the opening
  hand's land split is Draw Odds' (exact).
- **Draw Odds** (`Models/Hypergeometric.swift`, `DeckDrawOddsView`):
  exact hypergeometric — `Hypergeometric.exactly/atLeast/distribution`
  through `lgamma`; `DrawOdds` is the mainboard as rows (copies per
  name, the lands as a group) with cards seen by turn (7, +1 a turn, the
  play skips one), per-card odds by a chosen turn and in the opening
  seven, the lands' opening split, and for up to six tapped rows the
  odds of any (pooled copies) and all (inclusion–exclusion) by that turn.
- **Mana Base** (`Models/ManaBase.swift`, `DeckManaBaseView`): Karsten's
  colour targets computed, not copied — the sources at which the most
  demanding early spell of each colour (its pips on its turn) is castable
  in 90% of games where the land drops were made, as a nested
  hypergeometric (pool cards among the cards seen, sources among those,
  conditioned on at least `turn` pool cards); sources are lands and
  producers costing two or less; the land count by his 2022 formula
  (99: 31.42 + 3.13·MV − 0.28·cheap; 60: 19.59 + 1.90·MV − 0.28·cheap,
  scaled); the basics the deck runs re-split to meet every target then
  by pip share (every basic listed, so a colour with basics and no pips
  shows them going to zero); the non-basic sources only, each with
  "Holds" (a colour that drops below target without one copy).
- **Find a Commander** (`Controllers/Decks/CommanderFinder.swift`,
  `CommanderFinderView`, Decks › add menu): EDHREC's top hundred
  commanders (`/pages/commanders/{week|month|year}.json`) each scored by
  how much of its average deck (`/pages/average-decks/<slug>.json`,
  `deck.cards` as `["Name", n]` pairs by type — `EDHRECAverageDeck`) the
  collection holds (`CommanderMatch.score`: by front name, copies
  capped at what the list wants, from `CollectionStore.ownedCards`).
  One request per commander at EDHREC's pace, cached a week under
  `Caches/CommanderFinder`, rows inserted best-first as they land; the
  controller is a singleton so leaving the screen keeps the scan. A
  commander's page lists the missing cards with catalog prices
  (`DeckStore.items(names:)`; the owned ones are a count, not a list),
  Buy for the missing, Copy List for a new deck. A seeded run never fetches: the screen shows the offline error.
  A 403/404 page is "no average deck", not a failed scan.

The seed makes every fifteenth card a basic land (the five colours in
turn) so a seeded deck has a mana base for the tools. `DeckOddsTests`
(all four models), `DeckOddsTour` (UI: the three screens, two rows
combined, the "i", the finder offline).

## Deck analysis, recommendations, synergies

Ported from magicians-united's `deckcheck.php` (rules of thumb over
oracle text, no model) and kept pure so it runs off-main and under test:

- `Models/DeckAnalysis.swift` — `CardReading` reads one card once (roles:
  lands / ramp / draw / removal / wipes / tutors by regex, overridden by
  Scryfall's `otag:` lists when they are in; the colours it adds; fast
  mana, free interaction, extra turns, mass land denial by name list and
  text; the mechanics its text touches, from `DeckMechanic.all`).
  `DeckAnalysis.compute` turns a snapshot plus `DeckAnalysisSignals`
  (game changers, tag lists, Spellbook combos, Recommander scores — all
  optional) into composition against the floors (34·8·8·8·1·2), colour
  sources against Karsten (22 for one pip, 29 for two), the commander's
  engine, the Bracket (2–4 with every signal listed; 1 is a table
  agreement, 5 is declared), and three 1–10 scores — power (base 2, parts
  add), impact (base 1), playability (base 10, shortfalls subtract) —
  each with its parts, so the screen shows what moved it. Scores and the
  Bracket are for Commander formats; composition, sources and rules are
  read for any list.
- `Models/DeckPlan.swift` — keep score per row (roles ×1.5, overlap ×2,
  meta ×3, EDHREC-rank popularity, +12 for a combo piece), add score per
  candidate (gaps filled, sources short, overlap, meta ×6, +6 per combo
  completed, +1 owned, price penalties), then the table: identity
  problems and extra copies out first, fills while short, trims while
  over, swaps while the add beats the keep by 2 and no floor opens. Each
  row carries an effect: the deck re-scored with the swap applied, combos
  broken and gained by arithmetic on what Spellbook already returned. The
  `recommendations` list is every candidate scored against the deck as it
  stands. Candidates: the collection's spare cards (one per oracle id),
  Recommander's picks, the missing pieces of one-card-away combos
  (looked up on Scryfall once when the catalog lacks them).
- `Controllers/Decks/DeckAnalysisController` — one per deck
  (`shared(for:)`), keyed by the list hash. Publishes the local reading
  first (a detached task; nothing waits on the network), then each
  outside signal as it lands, then the plan. Combos are cached 30 days
  and meta scores 7 per list hash under `Caches/DeckAnalysis`;
  `AnalysisSignalSource` keeps the game-changer list (daily) and the
  seven `otag:` lists (weekly, six search pages per sitting, resumed
  across sittings, so a list never queues ahead of the user's own search
  in the 2/sec limit). `allowsNetwork` is false under `-uitest-seed`, and
  every screen says "needs a connection" rather than showing nothing.
- `Controllers/Cards/CardSynergyController` — the viewer's Synergies
  action (`CardSynergiesView`, pushed inside the viewer's stack like
  Details): three sections that say what kind of claim they are —
  Combos (Spellbook variants using the card), Played With It (EDHREC
  synergy for a commander page, lift > 1 for a card page, with the share
  of decks), Shares a Theme (`SynergyQuery`: the card's first three
  specific mechanics as an OR of their Scryfall terms, `-name:`, `id<=`
  the deck's identity when opened from a deck, `order:edhrec`). Names and
  ids resolve to `CardItem`s through `DeckStore.items(scryfallIDs:/
  oracleIDs:/names:)` off-main; unresolved names show as text. Cached a
  week per card under `Caches/Synergies`.
- `Models/CardReason.swift` — the one vocabulary every explaining row
  speaks (`ReasonLabel`: icon + short phrase, tinted by kind): "Combo
  with X", "Ramp, 7 of 8", "White source", "Tokens" (on plan), "Meta 82%",
  "+82% synergy" (a commander page, a share) / "79× as often" (a card page, EDHREC's lift, a ratio), "Lifegain", and for the cut side
  "No role" / "Off plan" / "Weakest of the list" / "Outside identity".
  The planner produces `tags` beside its sentences (the sentences stay
  for the tests and the keep-score text); the synergy controller maps
  Spellbook's feature names and EDHREC's numbers into it. A row shows one
  reason on its second line (`ReasonDetailLine`: reason · price · a check
  when owned — no mana pips and no "Not owned": with a four-pip cost and
  a price the reason was what got squeezed to "Infini…"), never the
  source's own sentence. Synergy sections show six rows and a "Show All
  N" row.
- UI: the add sheet has two scopes, All Cards and Recommended, and an
  **"In collection" chip** beside "Within identity" (not a scope): on
  All Cards it turns the Scryfall search into an in-memory search of
  what is owned (a browse of it with nothing typed — "+" opens there,
  chip on); on Recommended it narrows to what is owned (opens with the
  chip off, since the point is what the collection lacks). Recommended
  leads with **Commander Synergies** — EDHREC's whole list for the
  commander (`EDHRECSynergyLoader`, shared with the Synergies screen;
  `DeckAnalysisController.commanderPicks`, kept per commander), best
  first, cards already in the deck left out — then "For This Deck", the
  planner's list, each row with its reason, a loader while the plan is
  read, and a card just added kept in place as a stepper. The Stats row,
  the Analysis screen and the "…" menu open the sheet on Recommended.
  A viewer opened from a deck's Cards tab carries the deck's
  `DeckAddSession` (mainboard), so its bar steps the card's copies and
  the Synergies screen pushed from it can add to the deck. The swap table is
  `DeckSwapsView`, pushed from a banner row on the Cards tab whenever
  there is something to suggest (next to the issues row), from Stats,
  from the Analysis screen and from the menu. Stats leads with an
  Analysis section (three `Gauge`s, the bracket, floors met) after the
  Check section, and pairs the Mana Cost pie with Mana Production and a
  Colour Balance chart (each colour's share of pips against its share of
  sources, over the colours the deck casts). The controller caches the
  collection's candidates per collection revision and their readings
  across replans, so a signal landing re-plans without re-reading a
  thousand cards; `DeckPlan.id` lets views key rebuilds on one UUID.
  Measured by `DeckPlanTimingTests` on the real export (3,100 spare
  cards, debug build, simulator): the spare-card fetch 1.0s, the readings
  0.8s, the plan 0.3s — about two seconds behind the loader the first
  time, then a third of a second per replan. All of it off the main actor.
- Tests: `DeckAnalysisTests`, `DeckPlanTests` (pure), `AnalysisClientTests`
  (decoders over trimmed real responses in `Fixtures/`, the slug, the
  theme query), `DeckFlowTests.testAnalysisRecommendationsAndSynergiesOffline`
  (seeded, no network), and the tour's `05c`–`05h` and `04b` shots; `RealAnalysisTour` (opt-in by env) drives the same screens on the real collection with the network on.

## Set symbols and foil

Every set symbol draws at `SetSymbolView.scale` (1.2) times the size it
is asked for — one number, so they grew together when they read small.

Set symbols are **text**, from the bundled Keyrune font (`Resources/keyrune.ttf`,
SIL OFL; `keyrune-map.json` generated from Keyrune's CSS). Registered at
runtime with CoreText, so no Info.plist entry. Promo/token codes (`p…`, `t…`)
fall back to the parent set's glyph, as Keyrune itself does.

What Keyrune lacks is **worked out at build time**, not at first sight:
`scripts/make-set-icons.py` reads Scryfall's `/sets` (~1,050 sets, ~365
icons) and writes `Resources/set-icons.json` — each set Keyrune lacks mapped
to the icon Scryfall draws for it (`abro` → `bro`, `plst` →
`planeswalker`), 174 of which are Keyrune glyphs under another code — and
puts the 20 icons Keyrune has no glyph for into
`Assets.xcassets/SetIcons` as SVGs with preserved vector data and template
rendering, which Xcode compiles into the asset catalog. `SetSymbolView`
tries Keyrune by code, Keyrune by icon (`SetIcons.icon`), the bundled
vector (`SetIcons.assetName`), and only then the WebKit rasterizer — now
for sets released after the script last ran. Before, every set outside
the font went through WebKit on the main thread when first shown: a deck's
Recommended list and the viewer opened from it (EDHREC picks come from
all over Magic) paid WebKit's start-up. Re-run the script when a set
releases; the output is committed rather than fetched per build (a
network step in every build ties builds to Scryfall and breaks offline
and sandboxed script phases). `KeyruneFontTests` checks an alias, a
bundled icon drawing ink, and that every set in the real export resolves
without WebKit. `KeyruneFontTests`
draws a glyph and counts opaque pixels — the WebKit rasterizer could only ever
be checked by eye, and failed that repeatedly. WebKit remains as a fallback for
sets newer than the font: one persistent web view, SVG + PNG cached on disk
(read, decoded and written `@concurrent` — a Task made in the main-actor
loader ran them on the main thread; the SVG comes through `HTTPClient`,
never `URLSession.shared` from the main actor).

Foil sheen is a Metal shader (`Shaders/FoilSheen.metal`) applied with
SwiftUI's `layerEffect` (`FoilSheen` modifier) to the card image's own layer:
one GPU pass, samples the art, clipped with it. Static in the grid — the time
uniform is constant so nothing redraws; animated at 30fps only on the centred
viewer card; off under Reduce Motion. Building `.metal` files needs Xcode's
Metal Toolchain component: `xcodebuild -downloadComponent MetalToolchain`
(~700MB, installed here on 2026-09-20).

## Adding, editing and removing cards

`CollectionEditController.add / update / remove / createCollection`, all
writing AuditRecords under one actionID and bumping the tracker. Those
are single rows on the main context; **deleting a collection runs on
`CardMetaWriter`** (`runDelete`), since it is every row and an audit
record each — 3,900 of both on the real export, seconds on the main
thread when it ran there. Identity is
`mergeKey`, the same rule the import uses: adding a printing that matches an
existing row raises its quantity; editing a row so its identity matches
another row merges them. The collection can never hold two rows that mean
the same thing.

UI (`AddCardView`, from the viewer's Add action): one sheet holding a
`NavigationStack` + `Form`. The printing picker and collection picker are
*pushed*, searchable screens, not stacked sheets. Finish is a segmented
picker, language/condition are menu pickers, quantity is a `Stepper`,
purchase price is a currency `TextField` that defaults to Scryfall's market
price for the chosen finish and follows finish/printing changes until the
user types. New collection = native alert with a text field. Removal always
confirms (`confirmationDialog`), and owned rows also support swipe actions.
The sheet stays open after Add so several printings can go in; a success
haptic marks each. `EditEntryView` reuses `EntryFormSections`.

The viewer's info panel never changes shape between cards: four rows of
fixed height, every one always present — the name line (the copies as a
trailing "×2", or "In collection"; a leading "1×" used to cost the name
its room), the set line (language and condition chips trailing when
owned), the mana cost row (empty for a land, the added date trailing —
the one row with room), the price line. The name row is one accessibility
element (`viewer-name`: "Card 0, 2 copies, In collection"). A row that came and went, or a chip row only owned cards
had, shifted everything below it as the pager moved.

The viewer's bottom toolbar: Details (absent when the viewer was opened
from the detail screen), Edit, Add, then a flexible spacer and Remove on
its own. Edit and Remove are enabled only for a `CardItem.isEntry` — one
owned row; printings and search hits carry a Scryfall id, and their owned
rows are edited from the Add sheet's owned list. Remove confirms, then the
viewer steps to the neighbouring card (Photos after a delete) rather than
closing; it closes only when nothing is left. Nothing is shown that doesn't
work — deck and mark actions will join the toolbar when they exist.

## History, undo and redo

The History tab lists the ledger's user actions newest first and offers
Undo / Redo in the bar (Notes' and Freeform's placement; ⌘Z / ⇧⌘Z on a
keyboard). Any number of steps either way. Rows are named for their
cards — "Added Lightning Bolt", "Removed 3 Cards" with "Sol Ring,
Counterspell and 1 more · Main" under it, "Built Atraxa · from Main",
"Imported 3,846 Cards" — because at a fork two branches can both be
"Added Cards" (`HistoryAction.title` / `detail`; the store keeps the
three largest names, the printing count and the deck's name per
action). **The list shows the tree as branches** — git's idea without
git's chrome. `HistoryTimeline.lines()` decomposes it: the current line
(the applied path, then what Redo would take, out to a leaf) and every
other chain hanging off a placed line, nearest the head first; every
action is on exactly one line. One section per line: the current one
headed "Timeline · 3 applied · 2 to redo", each other headed by its name
or what it starts with ("Removed Sol Ring and 2 more") with "n actions ·
5 minutes ago", a **Switch** button (checkout: `jump(to: line.tip)`) and
a "…" menu with Rename (a List header takes no context menu). Where a
branch hangs is drawn both ways: the row it splits from wears a stub on
the rail and a tag naming the branch (tap: scroll to its card), and the
branch's card ends in a **junction row** — the rail runs into a small
dot, "Splits from Added Sol Ring in Timeline", and "Switch: 2 back, 1
forward", which is what Switch does (tap: scroll to that row). A rail in
the gutter (`HistoryRail`, a Canvas per row, rows with zero vertical
insets so it is continuous) draws each branch as a line with a dot per
action — solid where applied, dashed ahead of the head, a ring on the
head, hollow when undone, secondary for another branch. Deliberately not
a lane graph and not a toggle: no consumer Apple app draws a commit
graph, most histories never fork, and a second mode is a second thing
to keep right. Names (`HistoryBranchName`, a SwiftData table: actionID →
name) are set on the line's tip; a line's name is the one nearest its
tip, so it stays with the work it was given to — new actions on top
keep it, and it follows the branch when a later fork makes it the one
not taken. At a fork there is **no hidden gesture**: Redo becomes a
menu that opens on tap (Mail's reply arrow), listing the branches with
their lengths; a long-press menu and an action sheet were both tried
and dropped — nobody finds a long press, and a sheet over a list that
already shows the branches looked like a second UI. The replay's
"Working…" is a glass pill floating over the list, never a row, so
nothing shifts. Any row pushes
`HistoryDetailView`: what it did, when, Applied/Undone, copies in and
out, then the cards it changed — grouped by collection, or for a build
or disassembly by the *move* ("Main → Atraxa", each card once with its
art, printing and count) — largest first, at most
`HistoryDetail.visibleLimit` (40) per group with an "n more" footer, and
a search field only when there is more than fits (an import is
thousands; filtering runs off-main against a list held in an
`@Observable` model, never a `@State` array). One prominent button in a
bottom `safeAreaBar` does the one thing that makes sense for that row —
Undo / Undo Through Here (n back), Redo / Redo Through Here, or Switch
to This Branch (n back, m forward) — and flips as the replay lands. The
row's context menu offers the same in place. Built in three layers so
another kind of record can join later:

- **The ledger is never rewritten.** An undo is a new action of kind
  `.undo` whose records carry the negated deltas and `undoesActionID`;
  a redo is `.redo` with the original deltas. The ledger's sum is always
  the collection, and History shows what really happened. Undo/redo
  actions are not rows in History — they change the *state* of the
  action they name.
- **`HistoryTimeline` (Models) derives the state from the ledger** —
  pure, no SwiftData, exhaustively tested — and it is a **tree**, not a
  line. Replaying the actions in order: a user action's `parent` is the
  `head` (the applied action) at that moment, and it becomes the head;
  `.undo` moves the head to its parent; `.redo` moves it to one of its
  children. Applied = the path from the first action to the head;
  everything else is `undone`. The crucial case: undo several times,
  then do something new, and the head grows a *second* child — a fork.
  Nothing is superseded: undo back to the fork and `redoOptions` lists
  both children (`lastVisit` puts the branch taken most recently first,
  which is what a plain Redo takes), so the original branch can be
  redone to its end, or the new one, and `jumpPath(to:)` gets anywhere
  (undo to the shared action, redo down). A replay is always consistent:
  an action can only be redone when its parent is the head, which is the
  exact state it was recorded against. Stray undo/redo records that
  don't target the head (or a child of it) are ignored, not obeyed.
  Ordering is by timestamp with an id tie-break, so it is deterministic
  whatever order the rows come in.
- **`LedgerReplay` (Controllers/History) does the replay** on whatever
  context it is given (CardMetaWriter's, via `runReplay`, so undoing an
  import is off the main thread): each record's delta, negated or not,
  applied to the row with its merge key; a row that has to come back is
  rebuilt from the record's `EntrySnapshot` (language, price paid, set
  and number, a deck row's `sourceCollectionName`), falling back to
  CardMeta for older records; a deleted collection comes back with its
  rows. All-or-nothing per action: every row copies are taken from is
  checked first. `UndoController` (one per container) holds the
  `HistoryLog`, runs single or multi-step replays, and bumps both
  trackers.

Two things a replay refuses, with an alert: a deck that no longer exists
(its copies would land under a deck nobody can open — disassemble before
deleting, which the app does), and deck records written before this
existed, which carry the display label "Deck: Name" instead of the deck's
key (`DeckBuilder` now records `deck:<uuid>`; History labels it). Deck
*list* edits write no ledger and are not undoable — a list is a wish.

**A long history is shown through a window** (`HistoryLog.window`,
`HistoryWindow`): the newest forty actions of the current line — never
fewer than reach the head and one applied row under it — with a Show
Earlier row (how many more, and how many branches split from them), each
other branch's newest eight with Show All, and *no branch whose fork is
not drawn*: a card saying "splits from" an action that isn't on screen
points nowhere, so it comes into view with its fork. `HistoryLog.action`
is a dictionary lookup (a scan per row made a long list quadratic), and
the List is re-identified when the log's set of lines changes (not the
window's: Show Earlier bringing a branch into view must not throw the
list to the top), so a row that changes section (an undone action
becoming a branch when something new follows it) is drawn fresh rather
than animated across.
`UITEST_HISTORY_COUNT` seeds a long ledger with an old and a near branch
for `ChangesTour`.

**A row says where before it says what.** `HistoryAction.detail` leads
with the place ("Main · Sol Ring, Counterspell and 1 more"): the line is
cut at the row's width, and the place is what tells two actions on the
same cards apart. A list is marked ("Wants (list)"), and an action that
only touched lists shows its count plain with "on list" under it, not the
green of copies gained — putting eleven cards on a wishlist and later
adding the same eleven to a collection read as one action listed twice.

**A step that can't run says so first.** `LedgerReplay.blocker` is the
replay's own checks with no writes; `CollectionStore.history()` asks it
for the next Undo and each Redo on offer and the log carries the reasons
(`HistoryLog.blocked`; the check skips the CardMeta fetch a replay needs
for rows it makes — on an import's thousands of cards that was its cost).
The row wears a lock and the reason, the toolbar's
Undo/Redo and the detail screen's button are off with it as their label
(`UndoController.undoBlocker` / `redoBlocker`), instead of an alert after
the tap.

**Deleting a deck is an action** (`AuditAction.deckDelete`): one record
with a zero delta — the ledger's sum is untouched — whose `payload` is the
whole deck (`DeletedDeck`: the deck row, its list, its versions and
branches, as the backup's records). Undo puts it back with the same id, so
every build History holds against it names a deck that exists again and
can be replayed; redo deletes it again (refused while it is built). A
built deck is still disassembled first, as its own action. Creating a
collection and deleting an empty one are still not actions.
`docs/deck-versioning.md` has the reasoning.

Tests: `HistoryTimelineTests` (the rules; ten actions, undo five, two
new, undo two, redo the original five; forks at the root; jump paths),
`UndoRedoTests` (rows return intact, the fork with both branches reached
against the store, builds and disassemblies undo and redo with copies
conserved, an import undoes to empty and back, a deleted collection
returns, the refusals), `HistoryDetailTests` (titles and detail lines,
`historyDetail` merging printings and grouping by collection, a build
as moves, the cap and the filter, an import named by its size),
`HistoryFlowTests` (UI: undo a removal, redo it, undo again, add
something — the removal is now a branch section with Switch; undo that
and Redo's sheet lists both; take the original; rename the other from
its header; its detail screen switches back to it, name and all).
`HistoryTimelineTests` also covers `lines()` (a branch off a branch, a
fork at the start) and `UndoRedoTests` a name through switches, new
actions, renaming and clearing.

## Data flow notes

- **Card metadata is fetched for the whole collection, not just what scrolls
  past.** `CardHydrationController.hydrateAll` batches every id through
  `/cards/collection` (75 per request), applying per chunk so the grid fills
  progressively. Viewport-only hydration left most cards with no price or
  rarity, which silently broke every sort that keys on them.
- The sync runs as a **visible second phase of the import wizard** ("Fetching
  card data"), dismissable because it continues on the shared controller
  regardless. It also starts and resumes when a
  collection is opened. It is idempotent (`neededIDs` skips what is already
  fetched), so an interrupted run simply continues. It holds a background-task
  assertion so it survives the app being backgrounded briefly. `BGTaskScheduler`
  was deliberately not used: iOS gives no timing guarantee, and the work is
  attended and resumable.
- `CollectionEntry.card` is a real SwiftData relationship to `CardMeta`, and
  the grid's query sets `relationshipKeyPathsForPrefetching = [\.card]`. This
  replaced a second unbounded `@Query` over every `CardMeta` row plus a
  dictionary join rebuilt on each change.
- **Prices go stale, metadata does not.** `CardMeta.pricesUpdatedAt` drives
  `refreshPrices`, which re-fetches only cards older than
  `DataPolicy.priceTTL` (the Refresh Prices setting: 6h/12h/24h/manual)
  through the same batched endpoint.
- **The sync is the controller's, not a screen's.**
  `CardHydrationController.sync(pending:stale:context:)` runs metadata
  then prices as one owned `Task` (`syncTask`); the grid asks for it and
  awaits `syncTask?.value` only for its post-sync re-sort. It used to be
  the grid's own `.task(id: collection|revision)`: backing out cancelled
  a half-done price refresh and every write restarted it. `RootView`
  starts the same sync 5s after every foreground from
  `CollectionStore.dueForRefresh(stamp:)` (owned cards pending or past
  the cadence, off the row cache), so prices move on the cadence whether
  or not a collection is opened; skipped under `-uitest-*` so perf runs
  match. See `docs/data-loading-audit.md` for the inventory.
- **`DataActivity` (Utils) logs every load kind** (`DataTask`: catalog,
  rulings, card data, prices, backup, analysis signals, vocabularies,
  set list): the last run (start, end, count, note, failed) in
  UserDefaults, the current run's progress in memory. Loaders call
  `begin`/`progress`/`end`, or `skip` for a check that found nothing
  ("Checked · up to date"). Settings › Card Data › Data Activity
  (`DataActivityView`) shows what runs now with a bar, one row per load
  ("2 hours ago · 3,846 cards · 41s"), and a detail with what it is, when
  it runs (read from the live settings) and the last run. `UITestSeed`
  seeds the log (`seedForTesting`); `SettingsImportTour` shoots it.
- **The grid's glass cell glows with its card's art.** `ArtTint` is the
  average colour of the art's top and bottom thirds (a 12×16 rendering
  of the decoded thumbnail, microseconds, inside the `@concurrent`
  decode that already ran), pushed a little towards saturation and kept
  off black and white, cached per URL in `ImageMemoryCache` (a few bytes
  each, so it outlives the image). `CardTile` draws a gradient of the
  two colours *behind* the glass — the material does the softening and
  the bleed to the rim — and tints the glass with their mix. Never a
  blur of our own: a blurred copy of the art is an offscreen pass per
  tile, and the grid has 3,800 of them; a gradient and a tint are a fill
  each (real-collection scroll run: no app frame in any stall).
  `CardImageView(tint:)` hands the colour up when its image lands; a
  warmed tile reads the cache in its body for its first frame.
- Images live on disk (Caches/), not in SwiftData, to keep the store small.
  Two tiers: the bytes on disk, decoded tiles in memory by URL and size.
  `CardGridView` warms the next 30 tiles' images as tiles appear
  (`ImageLoader.warm`, sequential, cancelled when the user moves on), so
  a first scroll meets images already in memory.
- The grid rebuilds its `[CardItem]` on a **debounced** schedule: a full sync
  emits one SwiftData save per 75-card batch, and remapping thousands of items
  on each would thrash the main thread.

## Tests

`magic-hatTests` (Swift Testing) and `magic-hatUITests` (XCTest). Run:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun xcodebuild test -project magic-hat.xcodeproj -scheme magic-hat \
  -destination 'platform=iOS Simulator,id=<UDID of an iOS 26 device>' \
  -only-testing:magic-hatTests          # unit
  -only-testing:magic-hatUITests        # flow + performance
```

Use a device on the **iOS 26** runtime (`xcrun simctl list devices available`).
The app targets iOS 26, so xcodebuild silently filters out simulators on
older runtimes and then reports a baffling "visionOS not installed" error
rather than "no eligible device".

Tests never touch the network. `magic-hatTests/Fixtures/` holds real data:

- `ManaBox_Collection.csv` — a real export: 3,872 rows, eight binders, CRLF
  endings, 17 printings spanning more than one binder.
  `RealCollectionImportTests` imports it end to end and asserts the merged
  shape (3,846 rows, 6,563 copies, one row per merge key, one audit record
  per source row).
- `default_cards.slice.jsonl.gz` (2.2MB) and `rulings.slice.jsonl.gz`
  (0.5MB) — Scryfall bulk data filtered to exactly the printings that export
  references (3,467 cards, 7,411 rulings), plus `bulk-data.json`, the
  manifest. `BulkIngestTests` runs them through the real gzip reader,
  decoder and upsert (`BulkIngester`), then imports the CSV on top and checks
  the collection comes up fully hydrated.

Regenerate the slices with `python3 scripts/make-fixtures.py` (streams the
real bulk files once; takes a minute). Prefer extending these over inventing
rows — every bug so far came from the shape of real data.

The bulk *download* (`CatalogSyncController.download`) is the one thing not
covered; it is a `URLSessionDownloadTask` and testing it means testing
Foundation.

If `xcodebuild test` fails with `unable to find utility "simctl"`, the
active developer directory is CommandLineTools; run
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once.
`DEVELOPER_DIR` is not enough because xcodebuild spawns its own `xcrun`.

Unit suites cover the pure and store-level logic that has actually broken:
`CSVParser` (CRLF, quoting, duplicate headers), `mergeKey`, `CardSorting`
(determinism under shuffle), `PriceFormat`, `ImportController` against an
in-memory container (binder merge, add, replace, audit), `CollectionStore`,
`GzipLineReader` (tiny chunks, FNAME header, unterminated tail),
`CardSearchQuery` (every filter's Scryfall syntax, JSON round trip),
`ManaSymbol` (parsing, glyph coverage, a drawn glyph has ink),
`SearchController` (paging, empty vs failed, ownership) with a fake client.
`CardSearchQueryMatchingTests` covers the in-memory evaluation clause by
clause. `DeckListParserTests` (the real export), `DeckBuilderTests` (plan,
build, disassemble, conservation, audit pairs, list edits),
`DeckResolveTests` (the deck list against the bulk slice), `DeckStatsTests`.
`DeckFlowTests` (UI) creates a deck, adds from the collection search,
swipes between the pages, opens the export sheet (preview, only-missing),
builds, disassembles, locks, and imports from the clipboard — where the
issues row shows and the row right after the commander opens the viewer
on itself (the pager's initial position needs `anchor: .center`: without
it the second card, already peeking in, counted as visible and the
viewer stayed on the first). `SearchFlowTests` (UI) drives the landing filters, keyboard
dismissal and saving a search; `testCollectionSearchAndColorFilterNarrowGrid`
the collection's field and filter sheet. None needs the network.

UI tests launch the app with `-uitest-seed`: `UITestSeed` fills an in-memory
store with 900 image-less cards and marks the catalog ready, so nothing
touches the network. `ScreenshotTour` is not a test of behaviour: it
drives the seeded app through the screens and writes a PNG of each to
`TEST_RUNNER_UITEST_SHOT_DIR` for vetting a change by eye, and is
skipped when that isn't set. `testGridScrollDoesNotHitch` uses
`XCTOSSignpostMetric.scrollDecelerationMetric` — Apple's hitch counter; the
first run sets a baseline in the scheme and later runs fail on regression.
`testEnteringCollectionIsFast` clocks the push.

**The real collection, for real.** `RealCollectionTests` launches the app
with `-uitest-real`: an on-disk store kept between launches
(`UITEST_RESET=1` wipes it), the network on, and the real ManaBox export
(`UITEST_IMPORT_CSV`) imported on the first launch the way the wizard
does it — so metadata hydrates, prices refresh and images stream exactly
as they do for a user, only the 79MB catalog download is skipped. It
drives the flows that felt slow (entering the collection mid-sync, every
sort, scrolling real images, the first tap on Search, the first field
tap and typing, a real deck's rows and viewer, the add sheet over the
whole collection, `testTransitionsTour`: every push, sheet and tab once,
and `testRecommendedCardsOpenTheViewer`: a deck's Recommended scope and
two of its cards in the viewer) with the hang threshold at 100ms (`TEST_RUNNER_UITEST_HANG_THRESHOLD`
lowers it for an audit), and fails any step that stalled the main
thread, with the sampled stack in the message. For where the time goes
rather than whether it stalled, attach Time Profiler to the test's app
(`xcrun xctrace record --template 'Time Profiler' --device <udid>
--attach <pid>`, with `-parallel-testing-enabled NO` so the test runs on
that simulator and not a clone). Run
it alone — another simulator job on the same Mac starves the app and
every wait in system code shows up as a stall:

```
cp ~/Downloads/ManaBox_Collection.csv /tmp/perf/   # TCC guards ~/Downloads
TEST_RUNNER_UITEST_CSV=/tmp/perf/ManaBox_Collection.csv \
TEST_RUNNER_UITEST_PERF_DIR=/tmp/perf \
  xcodebuild test … -only-testing:magic-hatUITests/RealCollectionTests
```

Two launch-time records are the environment, not the app: UIKit loading
its accessibility bundle for XCUITest, and the keyboard prewarm's dlopen.

A behaviour change to anything above lands with its test in the same commit.

Two things the UI tests keep tripping on: a List or Form is lazy, so a row
below the fold is not in the accessibility tree until scrolled to — loop
`swipeUp` until `element.exists` rather than asserting on it cold (the
Stats page's Analysis rows, the Details page's Export row); and a
button-style `Toggle` is a `Switch` to accessibility, labelled with its
content ("Within identity, Red"). And an `accessibilityIdentifier` on a
`Section` is stamped on every element inside it, replacing the rows' own
ids (the synergy rows lost `deck-search-row-…` that way) — identify the
header text instead. When a run fails, the reason is in the
xcresult, not xcodebuild's output: `xcrun xcresulttool get test-results
tests --path <bundle>` and read the `Failure Message` nodes.

## Settings

A gear on the Collections tab opens `SettingsView` (Views/Settings). Every
preference is a UserDefaults key in `AppSettings` (Utils), bound with
`@AppStorage` and read nonisolated wherever it is needed:

- **Currency** (`DisplayCurrency`: USD = TCGplayer, EUR = Cardmarket, both
  from Scryfall's `prices`). `CardMeta` keeps `priceEUR`/`priceEURFoil`;
  `CardItem.price`/`priceFoil` are in the display currency *at the time the
  item was built*, so changing it bumps both trackers and every screen
  refetches (the store maps once per stamp and passes the currency down
  rather than reading defaults per card). `PriceFormat` prefixes the
  symbol; Scryfall's `order=`/`usd>=` become `eur` (`SearchSort.scryfallOrder`).
  A purchase price in another currency shows no gain/loss.
- **Grid size** (`GridDensity`, 2–5 across): `CardTile` decodes at
  `targetWidth(for:)`, the grid warms at the same size, the viewer's
  fallback matches, and the densest drops the caption.
- **Card language** — what new cards are added in (Add sheet, quick add,
  scan tray).
- **Card Data** — the catalog's build date, `CatalogSyncController
  .checkForUpdates()` (manifest only, compares builds and ignores the
  weekly interval) and `updateNow` (downloads what differs, in place with
  the sync bar — never the first-launch screen), **Update Automatically**
  (`autoCatalogRefresh`: off, the BGProcessingTask is never scheduled),
  cellular, a price refresh of every owned card (`force: true`, so it
  runs on cellular too), and Data Activity (above).
- **Adding** — default condition and finish (`defaultCondition`,
  `defaultFinish`) for the Add sheet, quick add and the scan tray.
- **Show Prices** (`showPrices`, the `\.showsPrices` environment set in
  `MainTabView`): off, the tile caption keeps the count, the overview
  card shows unique cards instead of value, and the viewer, detail
  screen, deck rows and reason lines drop their price — for a phone on a
  table. The seed clears every settings key at launch: UserDefaults
  persist between simulator runs, and a tour that failed with Show
  Prices off left the next run without prices.
- **Prices** — the refresh cadence (`PriceRefreshCadence`: 6h, 12h,
  daily, manually; `DataPolicy.priceTTL` reads it, and changing it bumps
  the tracker so the stores re-read what counts as stale) and Prices
  over Cellular (`refreshPrices` skips on a metered path unless forced).
- **Images** — Images over Cellular (`ImageLoader` refuses the network
  with `ImageLoadError.meteredNetwork`; what is on disk still shows) and
  Clear Image Cache with its size (`diskUsage`/`clearCache`).
- **Deck Analysis** — Online Signals (`onlineAnalysis`:
  `DeckAnalysisController.allowsNetwork`; off, the analysis is the local
  reading alone and every screen says so).
- **Backup & Restore** and **About** (version, contact —
  `AboutInfo.contactEmail` is a placeholder to replace — privacy policy,
  disclaimer, acknowledgements, all in-app text).

`CardMeta.metaVersion` below `currentVersion` counts as pending (like
`colorsRaw == nil` before it), so fields added to `apply` (the back face,
euro prices) backfill in one hydration pass. `isComplete` is the one test.

## Backup and restore

`AppBackup` (Models) is every user table as Codable records; a backup is a
zip (`ZipWriter`/`ZipReader`, Utils — raw DEFLATE via Compression, CRC-32,
no zip64) of one JSON file per table, a manifest (format version, counts)
and the collection as a ManaBox CSV. Dates are encoded exactly
(`deferredToDate`): History orders by timestamp, and ISO-8601 dropped the
sub-second part that keeps two same-second actions in order. Not included:
CardMeta, rulings, images — restored rows link to the phone's catalog and
anything missing is pending.

`BackupController` snapshots and restores on `CardMetaWriter` (a restore is
`delete(model:)` per table, then inserts); JSON and zip work is detached.
Restore **replaces** (merging two ledgers would break History's account)
and first writes "Magic Hat Before Restore …". `BackupScheduler` runs
daily/weekly backups when the app comes to the foreground (8s after), into
a folder picked with the document picker and kept as a security-scoped
bookmark — iCloud Drive with no entitlement — else `Documents/Backups`
(visible in Files: `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`).
The newest ten automatic backups are kept. `BackupTests` round-trips a
world through zip and restore and undoes afterwards.

## Selecting cards, anywhere

One selection for every screen that shows cards (`Views/Cards/CardSelection
.swift`): a collection or list, All Collection, search results, a set's
cards, a deck's list. The screen owns a `CardSelection`, hands it to
`CardGridView(selection:)` (or the deck's rows), applies
`.cardSelectionBar(selection, items:, actions:)` and hides its own toolbar
items while `selection.isActive`. A long press on a tile starts it with that
card (a deck row: Select in its long-press menu); Select Cards in the
screen's "…" menu starts it empty. The bar is the same everywhere: Select
All / Done on top; Add (to any collection, list, or deck board, copies =
the row's count, one for a search hit), Buy, the screen's own actions, the
count in the bottom bar's middle (a large title hides the principal slot),
destructive actions trailing. The tab bar hides; Back hides. Screen actions:
a collection's Move and Remove (never deck rows; on the writer, one History
action, `.move` is its own `AuditAction`), a deck's Move to board and Remove.
Every finished action says what it did in a toast and a VoiceOver
announcement (the overlay isn't reachable to VoiceOver).

The bar's body runs on every toggle, so it reads nothing per card: the
copies each row adds are a `[id: count]` map built off-main when
selection starts, an action's `isEnabled` is a closure evaluated by the
button, and the chosen `CardItem`s are gathered only when an action
runs (copying them in the title cost 0.2s with the whole collection
selected). Buy is a button opening a dialog, not a `Menu` whose content
is built with the bar. One `.sensoryFeedback` on the grid keyed on the
count, never one per tile: 3,800 tiles each observing the selection.

## Sorting, the same everywhere

`SortButton` (Views/Cards) is the only sort control on card lists: a
floating glass circle bottom-trailing, the options with the current one
checked, then Ascending and Descending, the current way checked — every
list sorts both ways. Collection grid (`CardSort`: Name, Mana Value, Price,
Rarity, Set, Quantity, Recently Added; `CardOrder` is a sort plus its
`SortDirection`, and the store's snapshot cache is keyed on both), a
deck's list and its add sheet (`DeckCardSort`), search results and a set's
cards (`SearchSort`). Picking another sort starts it its own way
(`defaultDirection`: prices, rarity, quantity and dates from the top,
names from A); ties always fall to name A–Z, and cards with no price or
date come last either way. Icons come from `SortIcon`, so an order has one
symbol everywhere. All persist (`collection.sort`, `deck.sort`,
`deck.add.sort.all|recommended`, each with a `.direction` key that is
empty for the sort's own way; Scryfall's in the query). The stored
"Price (High)" / "Price (Low)" from before the direction was its own
choice still read (`CardOrder(sortRaw:directionRaw:)`,
`DeckCardSort(stored:)`). The Decks tab's sort is a Files-style View Options menu,
because it sorts decks, not cards.

`CardStore` (Models/BuyLink) builds TCGplayer Mass Entry
(`massentry?productline=Magic&c=4 Name||…`) and Card Kingdom builder
(`builder?c=4 Name\n…`) links, values escaped by hand (URLComponents
leaves `&` and `+`). `BuyMenu` offers both; decks buy their missing cards
(`DeckSnapshot.missingBuyLines`) or the whole list.

The viewer's Add is a `Menu` with a primary action: tap opens the sheet, a
long press lists collections and lists that each take one copy of the
printing shown (`quickAdd`), confirmed with a toast. The Add sheet opens on
a collection (`AddTarget.resolve`: the one being browsed, through the
`browsingCollection` environment value; the row's own; the last used; the
only one).

## Scan

The Scan tab (Views/Scan, Controllers/Scan, `Utils/CardCamera`), camera
first in ManaBox's shape with native chrome: the picture edge to edge,
the tray's total in a glass capsule, a glass control column (review,
light, photo, type a name, settings), and the card just scanned in a
glass panel at the bottom. The layout is laid out, not computed — pills,
then the room left, then the panel (landscape: panel beside it).

**No frame by default** (`ScanSettings.showFrame`, off): a phone on a
stand never lines a card up with a box drawn on the screen. The whole
visible picture is read (`CardCamera.findsCard`): Vision's rectangle
detector finds the card — upright, a card's proportions, any size,
anywhere — the text is read inside that rectangle (so lines are measured
against the card exactly as from a guide, `Layout.card`), and an outline
follows it. With no rectangle (a white border on a white tray) all the
text is read and `CardTextReader.readPicture` works from what the lines
say (`Layout.picture`): the info block is the line with a real set code
and a language or number, the collector number on it or just above, the
title the topmost line above and over it. Rectangle results are
normalised to the region of interest, like text boxes. With Card Frame
on, the guide's measured frame feeds the dimming mask and Vision's
`regionOfInterest` (`CardCamera.guideRegion`, through the preview's
aspect-fill; `viewRect` is its reverse, for the outline).

The camera session and Vision (`VNRecognizeTextRequest`, accurate, no
language correction) run on the camera's own queue, ~4 frames a second,
one at a time. The default camera is the multi-lens virtual device (it
switches to macro close up); Scan Settings picks another
(`CardCamera.select`). `CardTextReader` (pure) reads the title band and the
bottom-left info block: collector number, a set code that must be a known
set, the language, and the ★ that marks a foil (• nonfoil).

`ScanMatcher`: set+number first (`GET /cards/:set/:number`), sure only if
the name agrees; else the fuzzy name (`/cards/named?fuzzy=&set=` with the
set read), sure at ≥ 0.88 similarity, otherwise it asks. The printing is
then narrowed by `printingQuery` — the number alone, the locked sets,
promos out — through one `unique:prints` search. `.outsideLockedSets` skips
a card with a message.

**Asked once.** "Not This" (`reject`) is remembered while the card stays
in view — the name read and the card offered; a reading within 0.8 of
either is not looked up or asked again (it used to match the offered
card's name only, so a misread title re-prompted forever) — and turns the
sheet into the name field in place (`Phase.manual`, one sheet for both:
`ScanPromptView`). The question's bar has Skip (carry on scanning, this
card left alone) and its body "No, Type Its Name" — two different ways
out, not the same one twice. A card nothing was found for is `.unmatched`: the
status pill says so and is the button to type it; the keyboard button in
the control column opens the same field. `ScanManualEntry` searches
Scryfall as you type (each word in the name, then the fuzzy match), and a
tap puts the card in the tray like any scan. Forgotten when the card
leaves the picture.

`ScanSession`: two of three frames must agree before a lookup; the card
just taken is ignored while it stays (`isSameAsLast`: same name and no
different printing read), and the same printing as the tray's head is
never a new row — another copy is the panel's +1. A different printing of
the same card is a new card. The panel edits the head in place: printing
(a horizontal strip of every printing from `PrintingsCache`, in the panel,
no navigation), finish (limited to the printing's `finishes`), language,
count; scanning pauses while the strip is open. Quick Mode off opens the
strip when the printing wasn't read. `ScanSettings` (UserDefaults): camera,
quick mode, locked sets, ignore promos, prefer foil, sounds, total, ignore
low values. The tray adds everything as one action
(`CollectionEditController.addMany`). A photo runs the same reader.
`-uitest-scan-demo` (debug) shows the chrome over a stand-in with real
cards from Scryfall, for `ScanTour`; the simulator has no camera.
`ScanTests`/`ScanSessionTests` cover reading, matching queries, no double
counts and the in-place edits; `visionReadsADrawnCard` runs Vision on a
rendered card.

A collection's or list's "…" menu (and an empty list's placeholder) has
Import (`CollectionImportView`): pasted text or a file, whatever made it.
`CardListReader` (Models/CardListFile) tells the shape from the text,
never the file's name: a **table** (commas, semicolons or tabs; quoted
fields; a BOM; Excel's `sep=` line) whose columns are found by header
name across ManaBox, Moxfield, Archidekt, Deckbox, Dragon Shield,
TCGplayer, Delver Lens, Deckstats, MTGGoldfish, Card Kingdom/CardSphere
and a spreadsheet of one's own (or no header: a count and a name); an
**MTGO .dek**; or a **text list** in any shape `DeckListParser` reads —
which now also takes "Name x4", bullets, "SB:", "[M10]" as a set, tabs,
Archidekt's "[Category]" and "^tags^", and `*E*` for etched. The sheet
says what it found (format, rows, copies, foils, how many name their
printing) before anything is added, and links to a page of every
supported shape with a sample. `CollectionImportController` matches each
row by the best thing it carries — Scryfall id, set + number, name in the
set it names (a set given by name is looked up in `/sets`), name — the
catalog first, Scryfall for the rest (case and accents folded:
`DeckImportController.patch`), keeps the row's finish, condition,
language and price paid, and adds everything as one `addMany` action. A
ManaBox export still goes through `ImportController` (it keeps ManaBox's
ids and dates). Unfound names are listed. The Collections tab's menu has
Import a File… and Paste a List…: a ManaBox export goes to the wizard,
anything else to the same sheet with a picker for the collection or list
(`CollectionImportView(collectionName: nil)`) — before, the tab only ever
took ManaBox and refused the rest. The sample files in
`magic-hatTests/Fixtures/import-*` are the contract (`CardListFileTests`).

## Search: Sets, and/or

The Search tab has a Cards | Sets picker as the first row of the landing
Form and of the Sets list — in the scrolling content, not a `safeAreaBar`:
under the large title a bar re-laid itself out on every frame of the
title's expansion, moving the content inset under the scroll, and a slow
glide to the top stuttered. `SetBrowserView` groups `/sets` by year
(`SetBrowsing`, pure; `SetKind` folds Scryfall's `set_type`), with owned
copies per set (`CollectionStore.ownedCopiesBySet`); a set pushes
`SetCardsView`, a `s:code` search in collector-number order. The set list
is cached a **day** (`ScryfallCatalogCache.setsTTL`), not a week, and pull
to refresh forces it — so a new set shows the day it is out. Search itself
is always live against Scryfall, so new cards appear there immediately;
only the on-device catalog waits for its weekly refresh (or Settings'
Check for Updates).

Type Line and Rules Text terms combine with `TermMatch` (and / or), a
connector chip between the included terms; exclusions always apply. Stored
as optional `typeLineMatchValue`/`oracleMatchValue` so saved searches
decode. `clauses(_:key:match:)` → `(t:dragon or t:elder) -t:legendary`;
`matches(_:_:match:)` is the in-memory twin.

## Decks: folders, link import, proposals

The Decks tab is `DeckBrowser(folderID:)` per level in a
`NavigationStack(path: [DeckRoute])` — subfolders inline-titled with the
always-shown search drawer, as every pushed screen (the automatic drawer
slid over a folder's first row); an ⓘ opens `DecksGuideView`; Select Decks
(View Options) moves or deletes several; List rows swipe for Move and
Delete: folders first (tiles with their
decks' covers, or list rows), then decks; icons or list and a sort
(`decks.layout`, `decks.sort`); drag and drop (`DeckDragItem` payload
strings) or Move (`DeckMoveSheet`); search is flat across folders and says
where each result lives.

`DeckSiteClient` turns a link into parser text: Archidekt's deck API,
Moxfield's v3 API (refused for apps behind its bot check — the error says
to Export and paste), MTGGoldfish's download (sideboard after the blank
line), or any plain-text URL. The import sheet has a link field; a link
pasted into the list is fetched. `DeckSiteTests` use trimmed real
responses.

`DeckPlan.propose` answers "what would I cut for these?": the swap
planner run with the user's picks as its only candidates, so a proposal is
judged exactly as a recommendation (swap for a named card with the
re-score, add while short, not clearly better than the weakest — named —
already in, outside identity). A **land is weighed against the lands**: the planner
never cuts a land, so a land offered to a deck with enough of them used
to be compared with the weakest *spell* (and a basic was not judged at
all). `propose` takes the place of the land worth least to the mana base
(`landValue`: the colours it makes that are at or under their target, its
utility, overlap, meta, popularity; a basic a little less) when the pick
is worth more, never leaving a colour short; while lands are under the
floor it goes the planner's way and takes a spell's place; and a spell
that beats no spell is offered a land's place when the deck runs
`landSurplus` (4) over the floor. A format with no size (casual) has room:
what isn't swapped is an add. Every proposal carries `options` — the
planner's cut first, then the next-weakest rows, each re-scored
(`swapEffect`) — because the planner's cut is a default. `DeckProposeView`
(Try Cards, from Swaps and the menu) shows one thing at a time: typing
shows results only, Try returns to the picks with the new one on top; a
pick is a card of its own (what comes in, what goes out as a menu of the
other cuts, the re-score, one button), and a pick that beats nothing can
be swapped in anyway by choosing what leaves. Swaps are hidden when a deck
is locked.

## Viewer: flip, smoothness, landscape

A double-faced card (`CardMeta.backImageNormalURL`, `ScryfallCard
.backImageURIs`) shows a flip button on the centred card; the back is only
built once asked for. Each page's shadow is a shape's behind the card
(inside the rotation), not the image's, which was an offscreen pass per
page per frame. The neighbours (±2) and the back are decoded at the
pager's size when the current card changes. Every size change re-pins the
current card, which fixed an off-centre card after rotating mid-swipe.

## Sorting

Every comparator in `CardSorting.sorted` must define a **total order**,
falling through to name and then id. `Array.sorted` is not stable in Swift, so
any key shared by many cards (e.g. every card with no price) otherwise comes
back in arbitrary, reshuffling order. Missing prices sort as 0, to the bottom.
