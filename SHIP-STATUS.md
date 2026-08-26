# Hansel ship status

started-at: 2026-08-26T21:34:26Z
stop-at: 2026-08-27T05:34:26Z

## Done
- A: plugin files at repo root from `abeant/dork-koplugin@f7355c5` (no git history, no nested `hansel.koplugin/`). Hansel rebrand, one-release dork→hansel migration (data files, Start with, gesture alias, settings key, kosync username dual-read). Tests pass. LICENSE AGPL-3.0.
- B: Hide unavailable books setting (default ON) in Library settings. Unreachable Grimmory overlays Downloaded ∪ Pinned without persisting the filter; setting off never auto-flips. Banner "Showing books on this device". Drawer Home row "On this device". Session untouched.

## Next
- C: UI polish (format chips uppercase, empty-set trap, Tools menu radios, settings copy).

## Log
- 2026-08-26T21:42:28Z A copied f7355c5 onto root, rebranded user-facing Dork/dork → Hansel/hansel, migration + tests, commit/push
- 2026-08-26T22:12:26Z B hide-unavailable overlay + On this device drawer, tests pass, commit/push
