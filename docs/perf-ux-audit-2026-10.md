# Performance and UX audit — October 2026

**Status (2026-10-13): every item below is fixed** except two judgement
calls: `BuyMenu` keeps an eager `lines` array (its remaining callers are
deck-sized; the 3,900-card collection menu builds its lines on tap), and
the playtest table lays out for landscape rather than locking to portrait
(a lock needs an AppDelegate orientation mask). A follow-up review of the
new concurrency code found and fixed three more: a waiter cancelled
mid-sleep kept its rate-limiter slot, a multi-step undo re-read the whole
ledger per step, and Clear Image Cache could be refilled by a load already
past its network step. 390 unit tests pass; the UI suite passes, with
`DeckFlowTests.testDragDeckIntoFolderInIconsView` and
`FeatureFlowTests.testListFromASelectionAndQuickAdd` failing only under
four parallel simulator clones (both pass run alone).

A full read of every view, controller, model, client and utility, plus the
uncommitted working tree, against CLAUDE.md's rules. ~100 findings,
de-duplicated and ranked. "Verified" means the code was read a second time
by hand; the rest were reported once and cite the exact lines.

## Tier 1 — fix first

| # | Where | Problem | Fix | Kind |
|---|---|---|---|---|
| 1 | `Views/Cards/CardSelection.swift:98-107`; callers `CollectionCardsView:142`, `SearchView:201`, `SetBrowserView:270`, `DeckDetailView:186` | `cardSelectionBar(items: [CardItem])` — a ViewModifier with `let items: [CardItem]`, so the whole collection (3,900) is element-compared on every screen update (keystroke, hydration merge, sort, selection toggle). The exact `Array.== → CardItem.==` cost CLAUDE.md measured at ~1s. Deck caller builds a fresh array per body. **Verified.** | Take a `CardItemList`; derive ids/copies inside; gather `[CardItem]` only when an action runs. | perf |
| 2 | `Utils/ImageLoader.swift:220-241`, `CardImageView:135,169`, `RateLimiter.swift:98` | `image(for:)` runs the fetch in an unstructured `Task` and only awaits it; cancelling a tile's `.task` or the grid's `warm` never cancels the request, and `RateLimiter.wait` has no cancellation check. A flick through a cold region queues one 5/s request per tile passed; the tiles on screen wait behind them. **Verified.** | Waiter count per key; `withTaskCancellationHandler`; cancel the task when the last waiter leaves; `Task.checkCancellation()` before `requestData` and in `wait`. | perf |
| 3 | `Utils/GzipLineReader.swift:122-126` | `takeLine` does `pending.removeSubrange(start...newline)` — `Data` memmoves the whole tail per line; with `pending` at 1–3MB and 112k lines the catalog ingest is tens of GB of memmove. **Verified** (unmeasured). | Read cursor into `pending`; compact once per `inflateMore`. | perf |
| 4 | `Views/Decks/DeckAddSession.swift:81`, `DeckEditController.swift:239-254`, `CollectionStore.dueForRefresh:160-168` | A card added to a deck from Scryfall search writes only a `DeckCard`; nothing writes its `CardMeta` and nothing hydrates deck-only cards (dueForRefresh walks owned rows). A card the weekly catalog lacks is a permanent name-only row: no art, price or type, passes legality/identity checks. **Verified** (no hydrate call on the deck path). | `DeckStore.snapshot` returns ids with no meta; `DeckDetailView.load` hands them to `CardHydrationController.hydrate(scryfallIDs:)`; or apply the `ScryfallCard` through `CardMetaWriter` at add time. | bug |
| 5 | `Controllers/History/UndoController.swift:79-86,140-153`, `LedgerReplay.swift:81-86` | Undo/Redo take the id from the cached `log.timeline` and `replay` never checks the action is still the head. Tapping Undo while the log is stale (tab just opened, write on another tab) writes negated deltas for a non-head action; the timeline then ignores that record as "stray" — copies gone, History still says Applied. **Verified** (no head check in replay). | Resolve the timeline on the writer's context inside `runReplay`; throw unless `actionID == head` (undo) / `parent == head` (redo). | bug |
| 6 | `Views/Decks/DeckPlaytestView.swift` (whole), `PlaytestHand.swift:215-225` | No landscape layout: hand 118pt fixed, bars ~104pt, 70pt bottom padding → ~60pt of battlefield for 89pt cards on a landscape phone; the 348pt preview runs off the top. Landscape is enabled in the target. | Lock the screen to portrait, or lay out hand/zones beside the table (as Scan does) and clamp the preview. | ux |
| 7 | `Views/Cards/CardGridView.swift:186` **(uncommitted)** | `lastAppeared` is `@State` written on every tile's `onAppear` before the `>= 3` guard, so the grid's body (ForEach over thousands of ids) re-runs per tile appearing — 3× more often than the old `warmedFrom` write. **Verified.** | Derive direction from `warmedFrom` (`index < warmedFrom`), delete `lastAppeared`; or hold it in a reference box. | perf |
| 8 | `Controllers/Collection/CollectionEditController.swift:424-445` | `update`: the `.manualRemove` record for the old identity takes `EntrySnapshot(entry)` *after* language/purchasePrice were overwritten; undoing an edit that changed finish + language restores the old finish with the new language and price paid. **Verified.** | Capture the snapshot before mutating, beside `oldKey`. | bug |

## Tier 2 — medium bugs

| # | Where | Problem | Fix |
|---|---|---|---|
| 9 | `Views/Cards/CardViewerView.swift:127,130`, `AddCardView.swift:113,116,286,365,373` | Remove alert, Add sheet owned rows and Edit sheet print raw `item.collectionName` — a built deck's row reads "Remove 1 from deck:8C0E…". `CardItem.displayCollection` is read by no view. | Use `displayCollection` in all five places. |
| 10 | `Views/Cards/CardViewerView.swift:296-303` | Quick add hardcodes Near Mint / normal for non-entries, ignoring Settings › Adding defaults (CLAUDE.md says quick add honours them). | Read `AppSettings.defaultFinish/defaultCondition`. |
| 11 | `Views/Cards/CardImageView.swift:168-173` | Any error (incl. `meteredNetwork`, 429 back-off) sets `didFail` → broken-photo glyph, never retried; with Images over Cellular off every uncached tile shows a failure glyph until Wi-Fi *and* the tile is recreated. | Keep the plain placeholder for metered/rateLimited; include a network-path revision in the `.task(id:)`. |
| 12 | `Controllers/Collection/CardHydrationController.swift:56-66,143` vs `CollectionCardsView:299-306` | `hydrateAll` (wizard) and `refreshPrices(force:)` run outside `syncTask`; a grid opened mid-import awaits a nil task and never does its post-sync re-sort (Price/Rarity sort stays in pre-hydration order). | Route every run through one owned task. |
| 13 | `CardHydrationController.swift:127-129`, `CardMetaWriter.swift:50-53` | `/cards/collection` `not_found` ids are never `markFailed`; they stay pending and are re-requested on every launch forever. | Decode `not_found`, mark `.failed` with `lastFetched`, back off a day. |
| 14 | `Models/PlaytestCard.swift:222-236` | `keywords(in:)` requires every comma-part known: "Flying, haste, backup 1" is thrown out whole → creature shown summoning sick, no vigilance. | Take known keywords from any line without a period/colon. |
| 15 | `Models/PlaytestCard.swift:142-147` | DFC "transform" detection misses craft / meld / disturb / incubate → read as modal → inspector offers casting the back face. | Add the words; or store Scryfall `layout` on CardMeta. |
| 16 | `Models/DeckAnalysis.swift:170-173,244,640,680` | Three regex false positives: `wipe` matches "each creature you control" (anthems); `draw` matches "opponent draws" (Nekusar, Rhystic); `removal` includes `counter target` so counterspells count twice in power/impact. | Tighten the patterns; count removal without counterspells. |
| 17 | `Controllers/Decks/DeckStats.swift:273-278` | Once text contains "Add", every coloured symbol in the whole text counts as production — `{B}, {T}:` activation costs become sources. | Parse only the "add …" group (reuse `CardReading.addGroup`). |
| 18 | `Views/Settings/SettingsView.swift:282-292,342-375`, `CatalogSyncController:225-253` | A failed "Download Update" is silent: `.failed` phase shown only while active; row reverts with no message. | Surface `.failed(m)` under the row. |
| 19 | `Views/Root/CatalogSetupView.swift:53-68` | First launch offline: `.failed`, only "Continue", no Try Again; the only retry is background/foreground. | Add Try Again calling `syncIfNeeded`. |
| 20 | `Utils/GzipLineReader.swift:156-158` | Truncated archive with a partial last line: `finished` never set, `next()` loops forever (unsure — depends on `compression_stream_process` FINALIZE result). | On EOF with nothing produced, throw `.truncated` or finish. |
| 21 | `Views/Decks/DeckDetailsView.swift:46-54,194-197` | Name commits `onSubmit` only — swipe to Cards or Back drops the edit (Notes autosaves). Format/Name/Notes editable on a locked deck under "A locked deck can't be changed". | Commit on focus loss; disable on `isLocked`. |
| 22 | `Utils/RateLimiter.swift:37,61`, `Clients/MTGJSONClient.swift` | MTGJSON requests go through `.other`, counted in Scryfall's shared 5/s bucket and frozen by a Scryfall 429; precon browsing eats hydration/search budget. | Add a `.mtgjson` category with its own lane. |

## Tier 3 — medium perf

| # | Where | Problem | Fix |
|---|---|---|---|
| 23 | `Views/Decks/DeckPlaytestView.swift:67-74`, `DeckDetailView:132` | Cover closure `if let snapshot { DeckPlaytestView(snapshot:) }` re-runs init — `PlaytestState(snapshot:)`, ~100 cards × 2 regex + shuffle, on main — on every DeckDetailView re-render while a game is up; `snapshot` nil → blank cover mid-game. | `fullScreenCover(item:)` carrying the snapshot; build the state lazily/off-main. |
| 24 | `Views/Decks/PlaytestHand.swift:283` | `finger = value.location` written on every drag change in `.pressing`/`.inspecting` too, though only read while `.dragging` → hand body (7 cards, 7 `CardImageView` inits) invalidates at touch rate for the whole hold. | Assign only in `.dragging`. |
| 25 | `Views/Decks/DeckCardsView.swift:78-83,118-124,137-170` | `filtered` runs `CardSearchQuery.matches` on main in `body`, evaluated twice per render; `sorted` re-sorts every section (parsing mana costs in the comparator) per keystroke and stepper tap. | Compute sections once in a `.task(id:)` on a detached task, as `CollectionCardsView` does. |
| 26 | `Models/CardSearchQuery.swift:545-548,632-634,570-573,613` | `matches(_:)`: locale-aware `range(of:options:)` per word × 4 fields × 3,900 cards per keystroke; re-derives `normalizedManaCost`/`ManaSymbol.parse` per card. | Fold query and card strings once (cache folded fields on `CardItem`), plain `contains`. |
| 27 | `Controllers/Decks/DeckAnalysisController.swift:111-117,153-154,173-186` | `refresh` runs on every list-hash change → every stepper tap cancels and refires a Spellbook POST + Recommander POST. | Debounce `run` ~1s; keep the local `publish` immediate. |
| 28 | `Controllers/Decks/PreconController.swift:99-117`, `PreconBrowserView:171-174` | Each tile's cover downloads the full ~570KB deck file in a controller Task the tile's cancellation never reaches; a fast scroll through "Everything" (3,000) queues ~1.7GB. | Cancel when no tile awaits it; cap concurrency. |
| 29 | `Views/Collection/CollectionsView.swift:44,178-182`, `ImportWizardView:16` | `@State parsedRows: [ManaBoxRow]` (3,872 rows) held by the tab for the session, compared row by row per parent update; never cleared. | Stamped reference box; clear on dismiss. |
| 30 | `Views/Search/SearchFilterSections.swift:599-600` | `SuggestingTextField` runs `suggest(text)` (10k-artist scan, main) before checking focus → every form re-render pays it while `query.artist` is non-empty. | `guard focus == field` first. |
| 31 | `Views/History/HistoryView.swift:133,157,207-213` | `.animation(value: undo.log.actions)` compares the whole `[HistoryAction]` per render; `currentRows.firstIndex(of:)` per drawn row (quadratic, uncommitted); `results` runs title/detail `localizedStandardContains` over every action on main per keystroke. | Key animation on head/stamp; position map in `feed()`; compute `found` in the debounced task. |
| 32 | `Views/Scan/ScanView.swift:264-269`, `ScanSession.swift:180-215` | `cardOutline` set under `withAnimation` every frame (jitter → perpetually animating); `phase` assigned without equality check → whole ScanView body ~2×/frame. | Hysteresis on the outline; `if phase != new`. |
| 33 | `Models/PriceHistory.swift:124-141`, `CardMetaWriter:109-110` | `init(packed:)` five `subdata` allocs per sample; `recordPrices` decodes + repacks every owned series per refresh batch (~7M allocs). | `withUnsafeBytes` + `loadUnaligned`; append for a new day. |
| 34 | `Models/HistoryTimeline.swift:83-85`, `CollectionStore.history:347` | `state(of:)` is `applied.contains` on an array, per action → O(n²) on long ledgers. | `appliedSet: Set<UUID>`. |
| 35 | `Controllers/Collection/CardSorting.swift:126`, `Models/Deck.swift:239` | Mana-value sort parses the cost twice per comparison. | Precomputed key / `manaValue` on `CardItem`. |
| 36 | `Models/DeckAnalysis.swift:252-254,461-469`; `DeckPlan.swift:254-296` | `CardReading` runs 20 mechanic patterns twice per card (0.8s over 3,100); `engine(of:)` compiles a regex per subtype per `compute` (~30× per plan); `bestAdd` builds reason strings for every candidate ~30× per plan. | Type-line patterns only for the second pass; cache engine; numeric score first, `why` for the winner. |
| 37 | `Controllers/Decks/DeckAnalysisController.swift:67-73,81-88`; `Utils/DiskJSONCache.swift:30,46-63`; `Utils/PrintingsCache.swift:27,65` | Three unbounded memory caches: per-deck controllers keep every spare `CardItem` + reading for the process; `DiskJSONCache.memory` never evicts (EDHREC pages are MBs each); `PrintingsCache.memory` grows per card rested on. | Share candidates by revision; LRU/NSCache; cap. |
| 38 | `Views/Cards/CardDetailView.swift:59-61,307-313,360-362,390,434-442` | `@State printingItems: [CardItem]` beside the `CardItemList`; `DateFormatter` per ruling per body; `lowestPrice` (UserDefaults read per printing) + `printings.map(\.id)` per body. | Drop the array; static formatter; compute once on load. |
| 39 | `Models/SetBrowsing.swift:71-78` | `releaseDate` allocates a `DateFormatter` per set row body in a 1,000-row list. | Static formatter. |
| 40 | `Views/Collection/CollectionCardsView.swift:201` | `BuyMenu` lines built eagerly inside `Menu` content over 3,900 cards per body (the selection bar deliberately avoids this). | Closure evaluated on tap. |
| 41 | `Views/Decks/DeckProposeView.swift:201-208,67-70,188-197` | `pick` clears `searchText`; a commander deck's identity keeps the query non-empty → one wasted Scryfall search per pick in the 1/s lane. | `guard hasCriteria` as `DeckAddCardsView.runSearch` does. |
| 42 | `Models/DeckListParser.swift:140-163`, `Models/CardListFile.swift:312-339`, `Controllers/Scan/CardTextReader.swift:176-178` | Regex compiled per call per line (5 per deck-list line, 2 per table row, 1 per candidate line per camera frame). | Static `NSRegularExpression`s. |
| 43 | `Controllers/Decks/DeckStore.swift:297-304,439-447` | `resolve`/`catalogRows` one `starts(with:)` fetch per unresolved name over unindexed `CardMeta.name` (112k rows). | One `contains(" // ")` fetch joined in memory, or `#Index` on `name`. |

## Tier 4 — medium UX

| # | Where | Problem | Fix |
|---|---|---|---|
| 44 | `Views/Cards/CardTile.swift:118-135,169-185` | Tile exposes no card name to VoiceOver (image unlabeled; caption is set/price). | `.accessibilityElement(children: .combine)` + label = name, value = set/number/price/copies, `.isButton`. |
| 45 | `Views/Decks/DeckRows.swift:243-249`; `DeckPlaytestView:456-535` | Deck stepper −/+ are 26×36pt; playtest zone strip ~28pt, command zone 42pt — under the 44pt minimum on the most-tapped controls. | 44pt `contentShape`s. |
| 46 | `Views/Collection/ImportWizardView.swift:244-255,303-341` | Replace mode clears a collection with no `.alert`; no `interactiveDismissDisabled(isImporting)` (swipe mid-import hides the progress); `hydrateAll` early-return flashes "Fetching" with nothing said. | Alert on Replace; disable dismiss; say "a sync is already running". |
| 47 | `Views/Decks/DeckAddCardsView.swift:745-746,379-396` | `ownedLoaded = true` before the search lands → "Nothing in Your Collection" flashes on every "+" open. | Keep the spinner until the first result lands. |
| 48 | `Views/Decks/DeckProposeView.swift:141-156` | `.idle` shows "No cards match." before any search ran. | Spinner/nothing for `.idle`/`.searching`. |
| 49 | `Views/Decks/DeckPlaytestView.swift:89-91`, `PlaytestHand:325` | Drag always plays `.front`; an MDFC's land back is unreachable by drag, and the drop copy doesn't say. | Prefer the face whose `issue` is nil; or two targets. |
| 50 | `Views/Decks/DeckPlaytestView.swift:51,116,619`, `PlaytestInspector:55` | `inspectorHeight` keeps the previous card's height → opens at the wrong detent, then animates. | Reset on `inspecting` set; estimate from option count. |
| 51 | All Playtest files; `CardViewerView:455,590,415-419` | No Reduce Motion handling: inspector 3D flip, preview scale, toast move, card lift/rotation, 90° tap; viewer flip spring and pager scrollTransition. Only FoilSheen checks it. | Read `accessibilityReduceMotion`; crossfade / drop scale. |
| 52 | `Controllers/Collection/CardHydrationController.swift:107,124` | Full sync batches `Array(needed)` from a `Set` (random order) and pre-claims every id in `inFlight`, so the viewport top-up is a no-op; after an import the tiles on screen fill at a random point in a ~50-batch run. | Order by the snapshot's sort; let the viewport window jump the queue. |
| 53 | `Views/Search/SearchFiltersView.swift:26-58`; `AddCardView.swift:325-398` | Filter draft sheet has no Cancel and swipe-down discards edits silently; `EditEntryView` same when dirty. | Cancel + `interactiveDismissDisabled` when dirty. |
| 54 | `Views/Decks/DecksView.swift:299-301,638-644` | Decks tab shows a bare `ProgressView` every launch until `overview()` (waits on `ownedIndex`, 0.35s fresh). | Persist the last `[DeckSummary]` like `LastOverview`. |
| 55 | `Views/Decks/DeckCardsView.swift:315-320`, `DeckEditController:179-194` | Set as Commander deletes the old commander row instead of moving it to main. | Move to `.main`. |
| 56 | `Views/Decks/DeckCardsView.swift:263-266,301-308` | Stepping a row to 0 leaves a "0" row until the next snapshot; − again is ignored. | Filter pending-0 rows. |
| 57 | `Views/Root/CatalogSyncBar.swift:23` | "Waiting for Wi-Fi" pill not tappable; no cellular opt-in from it. | Tap → alert "Use Cellular (80 MB)". |

## Tier 5 — low (batch when nearby)

- **Dup toast timers**: `CardSelection:135-151`, `DeckVersionsView:371-390` — toast `.task` not keyed on the message; second toast within 2s clears early. `.task(id: toast)`.
- **UserDefaults per tile**: `CardItem.gainLoss:163-166` + `CardTile:211,230,247` — `AppSettings.currency` read 3× per tile body. Compute in the store.
- **Init cost per construction**: `CardImageView:59-69`, `CardGridView:66-70` walk `connectedScenes` + NSCache per init. Static.
- **Dynamic Type**: `CollectionsView:548`, `CollectionCard:59` fixed 10/9pt fonts; `DecksView:831,887`, `PreconBrowserView:168`, `ToolGuideView:96-99` fixed tile heights; `ScanView:550-590` fixed-frame controls. Scale / `fixedSize`.
- **Button traits**: `CardDetailView:466-473`, `AddCardView:198-199` rows via `onTapGesture`; `ImportWizardView:260-275` binder rows no `isSelected` / ids.
- `CollectionStore:52,235,489-491` — snapshot cache keeps every sort/direction key forever; deleted collection keys never removed. Drop entries whose stamp ≠ the one written.
- `CollectionCardsView:346` — `refreshInPlace` asks a sorted snapshot per batch then discards the order.
- `CollectionCardsView:288` — thrown snapshot renders as "No Cards".
- `CollectionsView:273-281` — delete swallows the error; indeterminate overlay though `runDelete` reports a fraction.
- `CollectionImportView:275-281` — ManaBox branch double-bumps the tracker, `progress: { _ in }`, never `hydrateAll`. `:131` — `.task(id: source)` keyed on the whole file text. `CollectionsView:440-441` — ManaBox parsed twice.
- `ImportWizardView:153` — "Images and prices" (images aren't fetched); `existingCollectionNames` offers lists as collections.
- `PrintingPickerView:26-33,44` — filter on main per keystroke; ForEach over `[ScryfallCard]`.
- `ImageLoader:215-231` — `inFlight` keyed `url|px`; viewer + grid fetch the same bytes twice.
- `CardPriceHistoryView:72-92,122,181` — series unpacked 3× per render under `chartXSelection` (unsure it reaches a frame).
- `DeckPlaytestView:441-453,1016` — "Mana a/b" denominator counts summoning-sick creatures. `:380` — On the Play/Draw picker records an undo step. `PlaytestHand:305-309` — `armed` set outside `withAnimation`. `PlaytestTableViews:51` — `targetWidth: width * 2` on top of displayScale (600px for a 100pt card, three decodes per card). Fixed 64/100pt widths on iPad.
- `DeckStatsView:51-55` — Analysis from Stats lacks `onAddRecommended`. `DecksView:229-233` — Move sheet cancel ends selection. `PreconDeckView:186-191` — `importing` never renders. `DeckVersionsView:821-837` — diff rows can't open the viewer. `NewDeckView:117`, `DeckProposeView:152,164` — `List` over `[CardItem]` instead of `resultList.ids`. `DeckAddCardsView:548,207` — `session.quantity(of:)` in the sheet body's ForEach (verify). `:215,731-747` — collection write re-runs the live Scryfall search. `DeckDetailView:186,188,134-135,167` — `allItems.map` per render (goes with #1).
- `SearchFilterSections:288` — "Price (USD)" while the query emits `eur>=`. `SearchView:230-246` — locale-aware completions per render. `:114` — `DeckChangeTracker.revision` read in body. `SetBrowserView:49` — `regroup` keyed on `sets.count`. `FilterVocabulary:43-50,80` — offline refires nine catalog requests per appearance; partial load never retries.
- `HistoryView:478-499` — Redo Menu at a fork loses ⇧⌘Z.
- `ScanTrayView:37-39` — `onDelete` per offset while iterating (latent). `ScanView:76-79` — torch state never resets after `stop()`. `ScanSession:252-262` — "Or is it…" dismiss/re-present flash. `ScanSettingsView:199` — tips describe the frame that's off by default. `CardCamera:69,155,240` — `onFrame`/`requestedID` unlocked across queues.
- `SettingsView:251-253` — Refresh Prices Now builds a sorted All snapshot for ids. `:322` — Card Data section re-renders per progress tick. `DataActivityView:154` — `RelativeDateTimeFormatter` per row.
- `UITestSeed:32-40` — cleared keys omit `cardLanguage`, `scan.*`, `backup.*`, `bulk.allowCellular`. `BackupController:25-31` — `settingsKeys` miss `.direction`, `deck.add.sort.*`, scan, backup schedule.
- `HTTPClient:119-127` — non-Scryfall 429 is `badStatus`; CommanderFinder's "slow down" unreachable. `DeckSiteClient:225-233` — HTML check case-sensitive. `EDHRECClient:17-28` — `name` non-optional (unsure EDHREC omits it). `AnalysisSignalSource:75-82` — seven Sets rebuilt per run. `Goldfish:507-556`, `ManaBase:198-204` — allocations/recompute inside the loops.
- `Models/Playtest.swift:1061,312` — `spellsOnBattlefield`, `PlaytestSearchDestination.label` dead (uncommitted).
