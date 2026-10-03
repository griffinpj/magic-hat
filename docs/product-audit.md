# Product audit — what Magic Hat has, what it is missing

October 2026. A pass over every tab against what the apps people already
use for this (ManaBox, Moxfield, Archidekt, Delver Lens, Dragon Shield,
TCGplayer) do, and against what a collector actually does with a phone
at a table, at a shop, and on the couch.

## What is strong today

- Collection as a real data model with an append-only ledger, undo and
  branches; nobody else has History.
- Deck analysis and swaps that run offline over rules of thumb, with the
  outside signals (Spellbook, Recommander, EDHREC, Scryfall tags) layered
  on when they land.
- Scanning that reads the printing off the card, not just the name, and
  now works on a stand.
- Import that reads everyone's export, and deck versions with branches.
- Performance discipline: nothing heavy on the main thread, measured on
  a 3,900-card export.

## Gaps, ranked by how often a collector would hit them

### 1. Price history (killer feature, biggest gap)

The app shows one price and a gain since purchase. Every serious tool
shows a *trend*. We refresh owned prices every six hours and throw the
old number away.

- Keep a `PriceSample` table: scryfallID, date, usd, usdFoil (one row per
  card per day, only on change, pruned to ~1 year). 3,900 cards × 365 is
  1.4M rows at worst; in practice far fewer since prices move rarely.
- Then: a sparkline on the viewer's price row, a 7/30/90-day change on the
  tile and the detail screen, a collection-value chart on the Collections
  tab (the overview card is ready for one), "biggest movers this week" as
  a section, and an alert when a card you own crosses a threshold.
- This is the feature that makes someone open the app when they are not
  cataloguing.

### 2. Sell / trade workflows

The app answers "what do I have?" well and "what should I do with it?"
poorly.

- **Trade binder mode**: mark cards as for-trade (a flag, or a List kind
  `.trade`), with a share sheet that exports the trade list as text/CSV
  and a "trade value" total.
- **Sell sheet**: pick cards, see TCGplayer market vs. a buylist estimate
  (Card Kingdom publishes a buylist page per card; MTGJSON's buylist is
  server-side only — see CLAUDE.md), total it, export.
- **Set completion**: per set, owned vs. total with the missing list and a
  buy link (`CollectionStore.ownedCopiesBySet` already exists; the Sets
  browser is the natural home).
- **Duplicates / extras**: "copies beyond 4 (or 1 for Commander staples)"
  as a saved filter — the cards you can trade without hurting a deck.

### 3. Deck features people expect

- **Playtest / goldfish**: shuffle, draw seven, mulligan, draw. Small,
  fun, offline, and the thing people do with a new list.
- **Mana curve against the format**: Stats has the pie; add a histogram
  with the usual expected shape overlaid.
- **Tokens the deck makes**: Scryfall's `all_parts` gives token
  relationships; list them so the player knows what to bring.
- **Proxies / missing list print**: a one-tap PDF of the cards the deck
  is missing, 3×3 per page, for playtesting.
- **Sideboard guide / notes per card**: a note on a deck row ("in against
  blue"), kept in versions.
- **Deck sharing**: a share link via Moxfield/Archidekt text is covered;
  an image export (the list as a card-grid picture) is what people post.
- **Format banlist updates**: legality comes from Scryfall at hydration;
  show "legal as of <catalog date>" so a stale catalog isn't trusted.

### 4. Import wizard robustness

The ManaBox wizard is solid for what it does (binder selection, add vs.
replace, progress, audit). Three things:

- It only ever took ManaBox. As of this audit, the Collections tab's
  Import a File… hands any other file (another app's CSV, a list, a .dek)
  to the generic importer with a collection picker, and there is a Paste
  a List… entry beside it. Done.
- **No preview of what will change.** Add shows "n rows" but not how many
  rows merge into existing ones versus create new ones, and Replace does
  not show how many copies will be removed. A dry-run count
  (`ImportController` can compute both from `existingByKey`) belongs on
  the confirm step.
- **No per-column mapping fallback.** When the generic reader finds no
  Name column it gives up. A mapping screen ("which column is the name?
  the count?") would make any spreadsheet importable. Low frequency; the
  header aliases cover the real exports.
- Encoding: UTF-8, UTF-16, Windows-1252 and Latin-1 are tried in that
  order now. Excel's `sep=` line is handled.

### 5. Settings that are missing

- **Price source per finish / currency**: EUR is there; add "prefer
  Cardmarket for EUR" wording and a "show both" option on the viewer.
- **Default condition and finish** for Add and Scan (today Near Mint /
  Normal are hard-coded).
- **Tile caption options**: show price paid instead of market; hide
  prices entirely (people at tables don't want values on screen).
- **Hydration on cellular** (today only the catalog respects the toggle;
  images and price refreshes do not).
- **Haptics / sounds** in one place (scan sounds are in Scan Settings).
- **Backup**: iCloud sync of the store itself (SwiftData + CloudKit) is
  the real ask; backups to iCloud Drive are the stopgap.
- **Appearance**: an app icon set and a light/dark override are cheap
  wins.

### 6. Collections tab

- **Folders / nesting** for collections, as decks have (`DeckFolder`
  pattern copies over).
- **Sort collections** (name, value, size, recently changed) and
  reorder by hand.
- **Per-collection notes and a cover card** (the fan is automatic;
  letting the user pin the cover is a small delight).
- **Smart lists**: a saved search as a list ("all my foils over $10",
  "cards not in any deck") — `SavedSearch` + `CardSearchQuery.matches`
  already do the work; only the Collections tab needs to show them.
- **Not in a deck** as a built-in scope, next to All Collection.

### 7. Search

- Scryfall syntax passthrough is there via text; expose it ("Advanced:
  type Scryfall syntax") so power users know.
- Recent searches.
- Search inside a deck's list from Search results ("in deck X" chip).

### 8. Scan

- **Batch mode**: a stand plus continuous scanning is now possible; add a
  "keep scanning the same card = +1" toggle for counting playsets fast.
- **Scan from a photo of a binder page** (nine cards): Vision rectangle
  detection already finds cards; extend it to many per frame.
- **Condition on scan** (defaults to Near Mint): a quick chip row in the
  panel.

### 9. Platform

- **Widgets**: collection value, a random owned card, the last scan.
- **Spotlight / App Intents**: "add Lightning Bolt to Main", "what's my
  collection worth".
- **iPad layout**: the grid and the deck screen work; a sidebar for
  collections/decks would make it a real iPad app.
- **Share extension**: send a Moxfield link or a list from Safari into a
  new deck.

## Suggested order

1. Price history + sparklines + movers (the feature with no competitor
   gap to close, and the one that changes daily use).
2. Set completion + trade flag + sell sheet (turns the collection into
   decisions).
3. Playtest + tokens + missing-cards PDF (deck table-stakes).
4. Import dry-run preview; smart lists; collection folders.
5. Settings: default condition/finish, hide prices, cellular for images.
6. Widgets and App Intents.
