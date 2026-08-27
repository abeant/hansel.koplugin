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

### Fixed

- Settings → On this device crashed layout when any book was downloaded (`_` shadowed gettext), leaving a blank overlay that ate taps.
- Filter format list is the formats actually in the library (no seeded PDF/CBZ).
- Search is the previous Books/Authors/Tags/Categories dialog plus results sheet, with a search icon.
- Drawer/home no longer block the Lua thread on Grimmory HTTP (Android Close/Wait ANR). Offline cooldown skips probes for 20s.

### Changed

- Format filter labels are uppercase. Empty status or format is no filter and renders unchecked.
- Sort by file size, published date, or last opened.
- Tools → Hansel: Dashboard and All Books are radios, not fake toggles.

### Migration

Existing `dork.koplugin` installs keep working for this release: settings, catalog, cache map, sync queue, Start with, and the old gesture action still apply. New data files and Start-with use `hansel`.
