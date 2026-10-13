# Contributing

Hansel is a KOReader plugin (Lua 5.1 / LuaJIT). The plugin files are at the repo root (`_meta.lua`, `main.lua`, `lib/`, `ui/`). Do not nest a `hansel.koplugin/` directory in git; the zip wrapper is built at pack time.

## Tests

```sh
./tests/run.sh
```

Needs `luajit` or `lua` on `PATH`. The suite uses stubs in `tests/kostub.lua` and does not talk to Grimmory.

The download replacement regression uses only disposable files in a directory
that you create; it checks failed rename and empty responses preserve existing
editions. Run it separately with an explicit interpreter:

```sh
scratch_dir="$(mktemp -d)"
lua tests/test_library_download_preservation.lua "$PWD" "$scratch_dir"
```

Use `luajit` in place of `lua` to check that runtime when installed. The fixture
leaves its disposable files in the scratch directory for inspection.

```sh
luacheck --no-self _meta.lua main.lua lib ui
./scripts/package.sh
```

`package.sh` writes `hansel.koplugin.zip` with a top-level `hansel.koplugin/` folder. Do not commit that zip or a nested plugin directory.

## Pull requests

- Match the surrounding Lua: short comments, no unused placeholders.
- Keep user-facing strings as Hansel / Grimmory. Do not reintroduce the old Dork name outside the one-release migration code.
- LICENSE stays AGPL-3.0.
- Do not commit personal library data or invented screenshots.
- Device screenshots go in `docs/screens/` and must use the public-domain Classics library. See `scripts/shots.md` for the complete shot list and privacy checklist.

## License

By contributing you agree the work is AGPL-3.0, same as KOReader.
