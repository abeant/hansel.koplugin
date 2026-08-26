# Contributing

Hansel is a KOReader plugin (Lua 5.1 / LuaJIT). The plugin files are at the repo root (`_meta.lua`, `main.lua`, `lib/`, `ui/`). Do not nest a `hansel.koplugin/` directory in git; the zip wrapper is built at pack time.

## Tests

```sh
./tests/run.sh
```

Needs `luajit` or `lua` on `PATH`. The suite uses stubs in `tests/kostub.lua` and does not talk to Grimmory.

## Pull requests

- Match the surrounding Lua: short comments, no unused placeholders.
- Keep user-facing strings as Hansel / Grimmory. Do not add Dork, lattice, or IR product language.
- LICENSE stays AGPL-3.0.
- Do not commit `.docs/`, personal library data, or invented screenshots.
- Device screenshots go in `docs/screens/` (`home.png`, `drawer.png`, `detail.png`). See `scripts/shots.md`. Uncomment the README table after they exist.

## License

By contributing you agree the work is AGPL-3.0, same as KOReader.
