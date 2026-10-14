# Contributing

Hansel is a KOReader plugin (Lua 5.1 / LuaJIT). The plugin files are at the repo root (`_meta.lua`, `main.lua`, `lib/`, `ui/`). Do not nest a `hansel.koplugin/` directory in git; the zip wrapper is built at pack time.

## Tests

```sh
./tests/run.sh
```

When `LUA` is unset, the runner prefers `luajit`, then `lua` on `PATH`. An
explicit `LUA` value must name an available executable; it never silently falls
back to another runtime. Each run prints the selected executable and version.
Check the KOReader target runtimes explicitly when installed:

```sh
LUA=luajit ./tests/run.sh
LUA=lua5.1 ./tests/run.sh
```

An absolute interpreter path is also accepted. The suite uses KOReader stubs and
does not talk to Grimmory. The standard runner now includes both HTTP and library
download preservation regressions. It passes the repository root and distinct,
fresh disposable scratch directories to them, and stops on any failing suite.
It prints the scratch root and leaves these synthetic files for inspection;
it does not use reader settings, downloads or progress data.

To run only those two preservation regressions with an explicit interpreter:

```sh
scratch_dir="$(mktemp -d)"
mkdir "$scratch_dir/http" "$scratch_dir/library"
lua tests/test_http_preservation.lua "$PWD" "$scratch_dir/http"
lua tests/test_library_download_preservation.lua "$PWD" "$scratch_dir/library"
```

Use the installed KOReader target interpreter in place of `lua` when checking
LuaJIT or Lua 5.1. Each fixture preserves failures in its exit status.

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
