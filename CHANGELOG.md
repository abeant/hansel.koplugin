# Changelog

## [0.3.0] — Unreleased

First Hansel release. Plugin files live at the repo root.

### Added

- Cover-grid home for a Grimmory library (sign in, tap a cover, read).
- **Hide unavailable books** (default on): when Grimmory is unreachable, only show downloaded ∪ pinned books.
- **On this device** drawer row (browse) plus a separate Settings storage panel.
- Auto sync of reading progress (percent + XPointer). Off until you turn it on. Stands down if `grimmory.koplugin` or same-origin KO Progress sync is already active.
- Start with → hansel, and a **Show Hansel** gesture.
- Test connection from Settings.
- Comfortable / Compact / Dense grid (3×3 / 4×4 / 5×4).
- Hansel lockup (`hansel.svg`) on the GitHub README and the library drawer.

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

### Changed

- Format filter labels are uppercase. Empty status or format is no filter and renders unchecked.
- Sort by file size, published date, or last opened.
- Tools → Hansel: Dashboard and All Books are radios, not fake toggles.

### Migration

Existing `dork.koplugin` installs keep working for this release: settings, catalog, cache map, sync queue, Start with, and the old gesture action still apply. New data files and Start-with use `hansel`.
