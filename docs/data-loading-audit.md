# Data loading audit — what the app loads, when, and how it shows it

October 2026. Every long-running load the app runs on its own, how it is
triggered, how it is surfaced, what was wrong, and what changed.

## Inventory

| Load | Size | Trigger | Cadence | Surface | Thread |
|---|---|---|---|---|---|
| Card catalog (`default_cards`) | ~80 MB gz, 112k rows | first launch; `BGProcessingTask` (charging + Wi-Fi); Settings › Check for Updates / Update Now | weekly if a newer build exists (`DataPolicy`), off with Update Automatically off | `CatalogSetupView` (first launch), `CatalogSyncBar` (later), Settings › Card Data | background `URLSession`; ingest on `CardMetaWriter` at `.background` priority |
| Rulings | ~5 MB, 170k rows | with the catalog | weekly | same bar | same |
| Card data (hydration) | 75 cards/request | after an import (wizard phase 2); opening a collection; tiles scrolling in | once per card (`isComplete`), `metaVersion` bumps backfill | wizard "Fetching card data", grid "Syncing n/N" pill | Scryfall client off-main; writes on `CardMetaWriter` |
| Prices | same request | opening a collection; **now** also 5s after every foreground; Settings › Refresh Prices Now | `priceRefresh` cadence (6h/12h/24h/manual); skipped on cellular unless allowed | the same pill (it says "Syncing") | same |
| Images | per card | a tile or viewer showing it; grid warms the next 30 | forever on disk, Settings › Clear Image Cache | the tile itself; a spinner only in the viewer | `@concurrent` decode |
| Backup | ~1 MB zip | 8s after foreground | daily/weekly/off | Backup & Restore screen (last backup) | `CardMetaWriter` snapshot, zip detached |
| Analysis signals | 6 search pages per sitting | opening a deck's analysis / add sheet | game changers daily, `otag:` lists weekly, resumed across sittings | the section's own loading row | `@concurrent` |
| Search vocabularies | ~12k names | first open of the filters | weekly (`ScryfallCatalogCache.ttl`) | nothing (chips appear) | main-actor cache, fold detached |
| Set list | 623 KB | Sets browser, set filter | daily; pull to refresh | the list's own loader | same |
| Printings per card | one search | viewer resting on a card | 7 days on disk | detail screen fills | `@concurrent` |
| Deck analysis caches | small JSON | per list hash | combos 30 days, meta 7 | the analysis screen | `@concurrent` |

## What was wrong

1. **Prices only moved when a collection grid was opened**, and the
   refresh was the grid's own `.task(id: collection|revision)`. Backing
   out mid-refresh cancelled it after whatever chunk was in flight; any
   write (an add, a deck build) bumped the tracker and restarted it from
   the top. The Collections tab's value could be a mix of fresh and stale
   rows, and a user who browses by search or decks never refreshed at all.
   The cadence setting was a ceiling, not a schedule.
2. **Nothing recorded when anything last ran.** "Is it stuck?" and "did it
   ever finish?" had no answer short of the console. Backups, the signal
   lists and the vocabularies ran with no trace at all.
3. The pill says "Syncing" for both metadata and prices; harmless, kept.

## What changed

- `CardHydrationController.sync(pending:stale:context:)` owns the run as
  its own `Task` (`syncTask`). The grid asks for it and awaits
  `syncTask?.value` only for its post-sync re-sort; leaving the grid or
  a tracker bump no longer cancels the run. One run at a time.
- `RootView` on every foreground (5s after, behind the launch prewarms)
  asks `CollectionStore.dueForRefresh(stamp:)` — owned cards pending
  metadata and owned cards past the price cadence, from the row cache —
  and starts the same sync. Prices now move on the cadence whether or not
  a collection is opened. Skipped under `-uitest-*` so perf runs match.
- `DataActivity` (Utils): one log of every load kind (`DataTask`): the
  last run (started, finished, count, note, failed) in UserDefaults, the
  current run's progress in memory. Each loader reports `begin` /
  `progress` / `end`, or `skip` for a check that found nothing to do
  ("Checked · up to date"), so "last ran" is dated even when nothing
  downloaded.
- Settings › Card Data › **Data Activity** (`DataActivityView`): a Now
  section with a progress bar per running load, then one row per load
  with "2 hours ago · 3,846 cards · 41s"; a detail per load says what
  it is, when it runs (reading the live settings: cadence, automatic
  catalog updates, backup frequency) and the last run in full.

## Rate limiting (added 2026-10-03)

Scryfall sent a 429 with "FAILURE TO ACT WILL RESULT IN A NETWORK BLOCK"
during development. Causes: each API family paced only against itself
(search + collection + the rest = 14/sec against a 10/sec ceiling), no
back-off on a 429, and several copies of the app (phone, simulator, a
test run) each taking the full budget on one IP. Now: one shared bucket
at 5/sec for every API family, families halved inside it, images on
their own lane, and a 429 holding all Scryfall traffic for `Retry-After`
(60s default) with the countdown shown in Data Activity. See CLAUDE.md
"Rate limits".

## Still open

- The hydration pill could say "Updating prices n/N" during a price
  refresh; one flag drives both today.
- Rulings re-ingest with every catalog build even when only prices
  changed in the catalog; they are small and the ingest is background,
  so left alone.
- The vocabularies and set list could prefetch on Wi-Fi after launch so
  the first filter open is instant; today the first open waits a second.
