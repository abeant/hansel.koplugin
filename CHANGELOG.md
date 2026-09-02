# Changelog

## Unreleased

### Fixed

- Online/offline detection keys off the device's network link (`NetworkMgr:isConnected`), not KOReader's internet DNS probe. A LAN-only Grimmory no longer locks Hansel into offline mode, and a Wi-Fi drop is reflected immediately instead of after a request times out.
- A transport failure with the link up now reads **Server unavailable** rather than **Offline**; **Offline** means the device has no network.
- While Grimmory is unreachable with the link up, Home retries on a backoff timer (21s, 42s, … capped at 5 min) instead of waiting for a tap. `NetworkDisconnected` repaints from cache at once; `NetworkConnected` clears the probe cooldown.
- OPDS-only accounts report connection health from their own fetches, so shelves and feeds refresh for them too.
- Auto sync, cover fetches, the account screen, and the manifest walk all use the same link check, so they run on a LAN without internet.
- Token refresh and password login now respect the calling request's timeout budget instead of a fixed 8s/15s, so a stale token found during a 3s nav fetch cannot stall the UI for half a minute.
- Auto sync HTTP on Android uses 2s/4s timeouts (it runs on the UI thread there) to stay under the ANR budget.
- Home teardown through `UIManager:close` now cancels the recovery timer; a duplicate, dead `Home:onClose` was removed.

### Changed

- Settings writes are skipped when a scalar value is unchanged, and cache-map writes are coalesced to one per tick and only mark the library snapshot stale when a book's on-device state actually changes.
- The catalog keeps the 200 most recent page records instead of growing forever, and the full-library manifest walk flushes every five pages instead of every page.
- Cover downloads that fail are retried with backoff (5 min doubling to 1 h) instead of on every repaint.

## [0.3.0] — 2026-09-01

First Hansel release. Plugin files live at the repo root.

### Added

- Cover-grid home for a Grimmory library (sign in, tap a cover, read).
- **Hide unavailable books** (default on): when Grimmory is unreachable, only show downloaded ∪ pinned books.
- **On this device** drawer row (browse) plus a separate Settings storage panel.
- Auto sync of reading progress (percent + XPointer). Off until you turn it on. Stands down if `grimmory.koplugin` or same-origin KO Progress sync is already active.
- Start with → Hansel, and a **Show Hansel** gesture.
- Test connection from Settings.
- Comfortable / Compact / Dense grid (3×3 / 4×4 / 5×4).
- Hansel lockup (`hansel.svg`) on the GitHub README and the library drawer.
- Drawer lists Grimmory **Libraries** and **Shelves**. Categories is labeled **Genres**. Filter sheet has Library (Classics / Library) and Shelf (Unshelved, Favorites, …) chips. No Goodreads / personal rating / metadata-match.
- Shelf list includes **Unshelved** above Favorites (local filter — Grimmory has no `unshelved` facet).
- Library/shelf/magic rows use Grimmory Lucide icons (heart, book-open, inbox, …). Custom SVG icons are cached from `/api/v1/icons/{name}/content`.
- Libraries / shelves / magic shelves follow Grimmory View sort (creation date = id). Prefs load last and must not block those lists. Genres uses Lucide `shapes`.

### Fixed

- Settings → On this device crashed layout when any book was downloaded (`_` shadowed gettext), leaving a blank overlay that ate taps.
- Filter format list is the formats actually in the library (no seeded PDF/CBZ).
- Search is the previous Books/Authors/Tags/Categories dialog plus results sheet, with a search icon.
- Drawer/home no longer block the Lua thread on Grimmory HTTP (Android Close/Wait ANR). Offline cooldown skips probes for 20s.
- Boot paints from the on-disk catalog: no per-book disk stats, no startup HTTP, no hash-scan of Home.
- Skipping a Grimmory probe is not treated as “server down” (that hid the whole library). After first paint, sync Grimmory in the background.
- Light hydrate never stats disk. Cover pump and drawer REST do one HTTP per tick. Search hay uses CacheMap.get, not local_path.
- Sync/flush/shelf taps split across ticks. Catalog dumps once on idle. Hide overlay only on Session offline/server_error. Close/suspend persist without drain HTTP. Hash rebuild is one file per tick.
- Category/tag/series/author/shelf page turns no longer jump to “2 / 1” with an empty shelf. A missing feed-page cache is not an empty library: those views page over the catalog, same as All Books.
- Test connection now refreshes the Settings Connection row (it used to toast “signed in” while the row still said not checked).
- The open library now refreshes after Grimmory reconnects, including when Android misses KOReader's network-connected event and the next user interaction reveals the live connection.

### Changed

- Format filter labels are uppercase. Empty status or format is no filter and renders unchecked.
- Sort by file size, published date, or last opened.
- Tools → Hansel: Dashboard and All Books are radios, not fake toggles.

### Migration

Existing `dork.koplugin` installs keep working for this release: settings, catalog, cache map, sync queue, Start with, and the old gesture action still apply. New data files and Start-with use `hansel`.
