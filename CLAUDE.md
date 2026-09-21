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
  - Structure is flat: `MTGCollection` → cards. A collection shows all its
    cards in one grid; binder is stored on each entry as metadata, not a
    navigation level.
  - `MTGCollection` — a named collection (unique name). Import targets one
    collection: a new one, or an existing one to merge into.
  - `CardMeta` — cached Scryfall metadata (image URLs, dims), keyed by
    Scryfall ID; one per card, shared across collections.
  - `CollectionEntry` — one owned row (collection + binder + finish +
    condition + qty); mirrors a ManaBox CSV row. CSV fields are denormalized
    so the collection is browsable before hydration. `binderName` is retained
    as metadata (used to filter which rows to import) but not navigated.
  - `AuditRecord` — append-only ledger. Records sharing an `actionID` come
    from one user action; each has a signed `quantityDelta`. Backs the
    History tab and future undo/redo.
  - `ManaBoxRow` — parsed CSV row (the on-disk import schema).
- `Clients/` — API clients. Only describe endpoints + request/response
  shapes. `ScryfallClient` (`/cards/:id`, batched `/cards/collection`,
  `/cards/search` for all printings by oracle id).
- `Utils/` — cross-cutting infrastructure, no API-specific logic.
  - `HTTPClient` — transport, required headers (User-Agent/Accept), decoding.
  - `RateLimiter` — actor enforcing Scryfall per-endpoint limits.
  - `CSVParser` — RFC-4180-ish parser + ManaBox mapping.
  - `ImageLoader` — card image cache: original bytes on disk (Caches/),
    decoded+downsampled UIImages in memory keyed by URL+size. Decode and
    downsample run on the actor (off-main) via ImageIO so scrolling never
    triggers a main-thread decode of a full-resolution image.
- `Controllers/Collection/`
  - `ImportController` — applies a parsed import (add/replace), writes audit.
  - `CardHydrationController` — lazily fetches metadata for visible cards.

## Rate limits (Scryfall)

Enforced in `RateLimiter`. `/cards/search|named|random|collection` 2/sec,
`/cards/manifest` 10/min, everything else (incl. images) 10/sec. All requests
send an accurate `User-Agent` (`MagicHat/1.0`) and an `Accept` header.

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
(`prices.usd` / `usd_foil`) — that is what we show (no LOW/MID tiers). The
overlay shows the gain/loss vs the price paid at import (`CollectionEntry
.purchasePrice`) as `(±$Δ, ±%)`.

Set symbols: Scryfall serves set icons as SVG only. `SetSymbolLoader`
rasterizes the SVG once via an offscreen WKWebView snapshot (white on
transparent), caches it, and `SetSymbolView` renders it as a `.template`
tinted with `.primary` so it adapts to light/dark.

## Data flow notes

- Import does not fetch card data. Metadata/images are hydrated lazily when a
  binder is viewed, prefetching a lookahead window so scrolling stays smooth.
- Images live on disk (Caches/), not in SwiftData, to keep the store small.
