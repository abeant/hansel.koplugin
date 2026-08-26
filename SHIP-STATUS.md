# Hansel ship status

started-at: 2026-08-26T21:34:26Z
stop-at: 2026-08-27T05:34:26Z

## Done
- A: plugin files at repo root from `abeant/dork-koplugin@f7355c5` (no git history, no nested `hansel.koplugin/`). Hansel rebrand, one-release dork→hansel migration (data files, Start with, gesture alias, settings key, kosync username dual-read). Tests pass. LICENSE AGPL-3.0.
- B: Hide unavailable books setting (default ON) in Library settings. Unreachable Grimmory overlays Downloaded ∪ Pinned without persisting the filter; setting off never auto-flips. Banner "Showing books on this device". Drawer Home row "On this device". Session untouched.
- C: Format chips uppercase; empty status/format = no filter (unchecked, not all-on). Tools → Hansel Dashboard/All Books are radios. Test connection row. Grid density documented. Empty states and one primary detail action.
- D: README badges (KOReader / AGPL-3.0 / Lua / Grimmory), empty screenshot slots, CHANGELOG, CONTRIBUTING, quiet AI footer. No ChatGPT badge.

## Next
- E: scripts/package.sh + luacheck/tests CI + draft release on tag v*.

## Log
- 2026-08-26T21:42:28Z A copied f7355c5 onto root, rebranded user-facing Dork/dork → Hansel/hansel, migration + tests, commit/push
- 2026-08-26T22:12:26Z B hide-unavailable overlay + On this device drawer, tests pass, commit/push
- 2026-08-26T22:39:54Z C UI polish: uppercase formats, empty-set trap, Tools radios, Test connection, README settings/menu copy, commit/push
- 2026-08-26T23:05:51Z D badges, CHANGELOG, CONTRIBUTING, empty screenshot slots, commit/push
