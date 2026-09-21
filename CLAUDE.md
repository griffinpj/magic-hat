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
  - Planned, not built — decks are **hidden collections**, not a second
    concept. `MTGCollection` gains a `kind` (`.collection` / `.deck`); the
    Collections tab hides decks, an "All Collections" view shows everything.
    Building a deck **moves** rows: the source row's quantity drops (split,
    if only some copies go), a row is created in the deck collection carrying
    price/condition/date, and `sourceCollectionName` is recorded on it so
    unbuilding returns it home. Unbuild merges back via `mergeKey` — which
    works precisely because binder is no longer in the key. Every move is
    two AuditRecords (−n source, +n deck) under one actionID.
  - `AuditRecord` — append-only ledger. Records sharing an `actionID` come
    from one user action; each has a signed `quantityDelta`. Backs the
    History tab and future undo/redo.
  - `ManaBoxRow` — parsed CSV row (the on-disk import schema).
- `Clients/` — API clients. Only describe endpoints + request/response
  shapes.
  - `ScryfallClient` — `/cards/:id`, batched `/cards/collection`,
    `/cards/search` (printings by oracle id), `/sets/:code`. Primary source
    for card data, images and a single market price per finish.
  - `MTGJSONClient` — second provider, bulk-only (no per-card endpoint):
    `<SET>.json` per set and `AllPricesToday.json`. Its value is the full
    retail picture (low/mid/market/buylist across TCGplayer, Cardmarket,
    Card Kingdom) that Scryfall does not expose. Prices are keyed by MTGJSON
    UUID, so join via `identifiers.scryfallId` from a set file
    (`scryfallToUUID(setCode:)`). `AllPricesToday.json` is tens of MB —
    only ever fetch it from an explicit user action with progress.
- `Utils/` — cross-cutting infrastructure, no API-specific logic.
  - `HTTPClient` — transport, required headers (User-Agent/Accept), decoding.
  - `RateLimiter` — actor enforcing Scryfall per-endpoint limits.
  - `CSVParser` — RFC-4180-ish parser + ManaBox mapping.
  - `PrintingsCache` — "all printings of this card" by oracle id. Written to
    disk with a 7-day TTL (printings only change when a set releases), so
    cold launches don't re-run searches. The card overlay warms it for the
    card on screen, debounced, so opening the detail screen is instant.
  - `SetSymbolLoader` — see Set symbols below.
  - `ImageLoader` — card image cache: original bytes on disk (Caches/),
    decoded+downsampled UIImages in memory keyed by URL+size. Decode and
    downsample run on the actor (off-main) via ImageIO so scrolling never
    triggers a main-thread decode of a full-resolution image.
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
- Hydration bumps `CardHydrationController.revision` per 75-card batch;
  views refetch on a **debounce** (longer while a sync is running) and merge
  in place without reordering, so the grid doesn't reshuffle mid-sync.
- Small tables (`MTGCollection`, per-oracle rulings) are fine as `@Query`.

For this to compile, the `@Model` classes, `CardItem` (and its extensions),
and the enums they use are all `nonisolated` — opted out of the project's
default MainActor isolation. Without that no data work can leave the main
thread. New model/value types must follow suit.

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
- SwiftData `@Model` types are main-actor-bound under this project's default
  MainActor isolation, so their writes happen on the main context. For large
  writes, chunk the loop and `await Task.yield()` between batches so the run
  loop stays responsive, and surface progress (e.g. a progress bar) rather
  than blocking behind a spinner.
- Long-running user actions should show progress and keep the UI interactive
  (or explicitly disable only the controls that must not change mid-operation).

## Reusable card UI

Card browsing is built from generic, source-agnostic components so Search can
reuse them later (they take plain values, not SwiftData/Scryfall models):

- `CardItem` (Models/) — presentation value type for one card. Build it from
  `CollectionEntry`+`CardMeta` (owned) or, later, from a `ScryfallCard`
  (search). Carries `owned` so non-owned results can dim.
- `CardGridView` — 3-wide grid of `[CardItem]`; `onAppearIndex` lets the
  parent hydrate/prefetch. Tap → overlay; overlay eye → detail push.
- `CardOverlayView` — enlarged card in a horizontal pager that peeks
  neighbours; swipe flows through the grid. Info panel + Liquid Glass action
  bar (only the eye action is wired; others are placeholders).
- `CardDetailView` — hero art header, gameplay text, Versions/Ruling tabs,
  and all printings (grouped by set) with owned indicators.

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
2. A real `URLSessionDownloadTask` (bytes land in a file, not memory) with
   delegate progress. `allowsExpensiveNetworkAccess` and
   `allowsConstrainedNetworkAccess` are false and `waitsForConnectivity` is
   true, so a ~79MB catalog waits for Wi-Fi rather than spending cellular.
3. `GzipLineReader` pulls the file a line at a time. It is hand-rolled because
   Foundation only gunzips when the server sends `Content-Encoding: gzip`
   (these are files whose content is gzip), and Compression speaks raw DEFLATE,
   so the gzip header is parsed and skipped by hand.
4. Parsing runs on a detached task; each decoded batch is awaited onto the main
   actor to be written. SwiftData models are main-actor-bound here, so this
   keeps JSON off the main thread while writes stay where they must be — and
   awaiting each batch throttles the reader, so memory stays flat.

`CatalogSyncBar` narrates it above whichever tab is showing. Two things that
matter for scrolling: the bar observes the controller itself (reading `phase`
from `MainTabView` would re-render every tab on each batch), and ingest
progress is reported once per ~10 batches rather than per batch.

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
so it adapts to light/dark. Two non-obvious constraints: WebKit only paints a
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
- **Later refreshes** — `CatalogSyncBar`, a thin glass strip above whichever
  tab is showing. Non-modal; the app stays usable on the data it has.

Network: the catalog refuses metered paths unless the user opts in. That is
made *visible* — `.waitingForWiFi` phase, "Use cellular data (80 MB)" button
— because `waitsForConnectivity` alone left the bar at 0% forever with no
explanation. Rulings (~5MB) are allowed anywhere. `NetworkMonitor` wraps
`NWPathMonitor`.

Refresh policy (`DataPolicy`): a newer bulk build is taken only if our copy
is older than 7 days (catalog) / 1 day (rulings). Scryfall rebuilds daily
and 79MB a day is not worth it; owned-card prices already refresh every 6h
through the cheap batched call.

## Set symbols and foil

Set symbols are **text**, from the bundled Keyrune font (`Resources/keyrune.ttf`,
SIL OFL; `keyrune-map.json` generated from Keyrune's CSS). Registered at
runtime with CoreText, so no Info.plist entry. Promo/token codes (`p…`, `t…`)
fall back to the parent set's glyph, as Keyrune itself does. `KeyruneFontTests`
draws a glyph and counts opaque pixels — the WebKit rasterizer could only ever
be checked by eye, and failed that repeatedly. WebKit remains as a fallback for
sets newer than the font: one persistent web view, SVG + PNG cached on disk.

Foil sheen is a Metal shader (`Shaders/FoilSheen.metal`) applied with
SwiftUI's `layerEffect` (`FoilSheen` modifier) to the card image's own layer:
one GPU pass, samples the art, clipped with it. Static in the grid — the time
uniform is constant so nothing redraws; animated at 30fps only on the centred
overlay card; off under Reduce Motion. Building `.metal` files needs Xcode's
Metal Toolchain component: `xcodebuild -downloadComponent MetalToolchain`
(~700MB, installed here on 2026-09-20).

## Adding, editing and removing cards

`CollectionEditController.add / update / remove / createCollection`, all
writing AuditRecords under one actionID and bumping the tracker. Identity is
`mergeKey`, the same rule the import uses: adding a printing that matches an
existing row raises its quantity; editing a row so its identity matches
another row merges them. The collection can never hold two rows that mean
the same thing.

UI (`AddCardView`, from the overlay's middle action): one sheet holding a
`NavigationStack` + `Form`. The printing picker and collection picker are
*pushed*, searchable screens, not stacked sheets. Finish is a segmented
picker, language/condition are menu pickers, quantity is a `Stepper`,
purchase price is a currency `TextField` that defaults to Scryfall's market
price for the chosen finish and follows finish/printing changes until the
user types. New collection = native alert with a text field. Removal always
confirms (`confirmationDialog`), and owned rows also support swipe actions.
The sheet stays open after Add so several printings can go in; a success
haptic marks each. `EditEntryView` reuses `EntryFormSections`.

The overlay action bar: pencil = edit (owned only), middle = add (any card,
including printings from the detail screen), trash = remove (owned only,
confirms, then closes the overlay). Deck and mark actions remain stubs.

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
`GzipLineReader` (tiny chunks, FNAME header, unterminated tail).

UI tests launch the app with `-uitest-seed`: `UITestSeed` fills an in-memory
store with 900 image-less cards and marks the catalog ready, so nothing
touches the network. `testGridScrollDoesNotHitch` uses
`XCTOSSignpostMetric.scrollDecelerationMetric` — Apple's hitch counter; the
first run sets a baseline in the scheme and later runs fail on regression.
`testEnteringCollectionIsFast` clocks the push.

A behaviour change to anything above lands with its test in the same commit.

## Sorting

Every comparator in `CardSorting.sorted` must define a **total order**,
falling through to name and then id. `Array.sorted` is not stable in Swift, so
any key shared by many cards (e.g. every card with no price) otherwise comes
back in arbitrary, reshuffling order. Missing prices sort as 0, to the bottom.
