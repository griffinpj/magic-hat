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
  - `CardMeta` — cached Scryfall metadata (image URLs, dims), keyed by
    Scryfall ID; one per card, shared across binders.
  - `CollectionEntry` — one owned row (binder + finish + condition + qty);
    mirrors a ManaBox CSV row. CSV fields are denormalized so the collection
    is browsable before hydration.
  - `AuditRecord` — append-only ledger. Records sharing an `actionID` come
    from one user action; each has a signed `quantityDelta`. Backs the
    History tab and future undo/redo.
  - `ManaBoxRow` — parsed CSV row (the on-disk import schema).
- `Clients/` — API clients. Only describe endpoints + request/response
  shapes. `ScryfallClient` (`/cards/:id`, batched `/cards/collection`).
- `Utils/` — cross-cutting infrastructure, no API-specific logic.
  - `HTTPClient` — transport, required headers (User-Agent/Accept), decoding.
  - `RateLimiter` — actor enforcing Scryfall per-endpoint limits.
  - `CSVParser` — RFC-4180-ish parser + ManaBox mapping.
  - `ImageLoader` — two-tier (NSCache + disk under Caches/) card image cache
    with in-flight coalescing.
- `Controllers/Collection/`
  - `ImportController` — applies a parsed import (add/replace), writes audit.
  - `CardHydrationController` — lazily fetches metadata for visible cards.

## Rate limits (Scryfall)

Enforced in `RateLimiter`. `/cards/search|named|random|collection` 2/sec,
`/cards/manifest` 10/min, everything else (incl. images) 10/sec. All requests
send an accurate `User-Agent` (`MagicHat/1.0`) and an `Accept` header.

## Data flow notes

- Import does not fetch card data. Metadata/images are hydrated lazily when a
  binder is viewed, prefetching a lookahead window so scrolling stays smooth.
- Images live on disk (Caches/), not in SwiftData, to keep the store small.
