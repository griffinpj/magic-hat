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
History, Search). Shared layers (Models/Clients/Utils) stay flat because they
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

Enforced in `RateLimiter`. `/cards/search|named|random|collection` 2/sec,
`/cards/manifest` 10/min, everything else (incl. images) 10/sec. All requests
send an accurate `User-Agent` (`MagicHat/1.0`) and an `Accept` header.

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
  which are looked up and fail like any other) is resolved on a
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
  list edits) stay on the main context. The main actor learns of
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
- `CardDetailView` — hero art header, gameplay text, Versions/Ruling tabs,
  and all printings (grouped by set) with owned indicators. Mapping the
  printings to cards and filtering/grouping them (per keystroke in
  "Filter sets") run on a detached task — a basic land has hundreds.
- Present the viewer with `.fullScreenCover(item:)` over a
  `CardViewerSession` — the items, the current id and any deck target
  travel *in the item*. Reading them from the presenter's other `@State`
  gave a blank viewer from a deck's search results: inside an active
  search session the presentation closure was evaluated against a copy
  of the presenter whose state was still at its initial values. The item
  is the one thing SwiftUI hands the closure fresh.
- Owned vs not: `CardItem.isEntry` (an owned row with a quantity) vs
  `CardItem.owned` (a search hit/printing we hold somewhere). The tile is
  the art, clean, over a two-line caption (Photos/App Store register):
  the price in primary (a gradient ✦ first for foil/etched, a tertiary
  dash until prices arrive) with the copies as a small "×2" count at the
  trailing end *only when more than one* (a green check for an owned
  hit) — the common case stays clean — and "◆ #123" in secondary: the set
  symbol in its rarity's colour (a set neither Keyrune nor the bundled
  icons draw shows its code — no WebKit from the grid) and the collector
  number. No gain/loss on the tile; the viewer's price line has it. The
  zoom's source is the image, not the caption (`CardTile(zoom:)`). No dimming, so results look like the
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
(cards, market value, and the share built into decks) and a synthetic
"All Collection" — `CollectionScope.allKey`, a scope the store understands
rather than an `MTGCollection` row — that lists every owned row across
every collection and every built deck, each labelled with where it lives.
Its row is the name alone: count, value and the card fan would repeat
the overview card above it. The rows are glass cards pushed through a
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
fixed height, every one always present — the name line ("In collection"
trailing), the set line (language and condition chips trailing when
owned), the mana cost row (empty for a land), the price line (the added
date trailing). A row that came and went, or a chip row only owned cards
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
keyboard). Any number of steps either way. At a fork Redo is a menu with
a primary action — a tap takes the most recently taken branch, a long
press lists every branch with its length — and a row's context menu
jumps several steps: "Undo Through Here", "Redo Through Here", or
"Switch to This Branch" (n back, m forward). Built in three layers so
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

Tests: `HistoryTimelineTests` (the rules; ten actions, undo five, two
new, undo two, redo the original five; forks at the root; jump paths),
`UndoRedoTests` (rows return intact, the fork with both branches reached
against the store, builds and disassemblies undo and redo with copies
conserved, an import undoes to empty and back, a deleted collection
returns, the refusals), `HistoryFlowTests` (UI: undo a removal, redo it,
undo again, add something, nothing to redo from there; undo that and
Redo is back with both branches marked).

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
  `refreshStalePrices`, which re-fetches only cards older than
  `CardHydrationController.priceTTL` (6h) through the same batched endpoint.
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

## Sorting

Every comparator in `CardSorting.sorted` must define a **total order**,
falling through to name and then id. `Array.sorted` is not stable in Swift, so
any key shared by many cards (e.g. every card with no price) otherwise comes
back in arbitrary, reshuffling order. Missing prices sort as 0, to the bottom.
