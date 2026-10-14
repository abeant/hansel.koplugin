#!/bin/sh
set -e
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "${LUA+x}" = x ]; then
  if [ -z "$LUA" ] || ! command -v "$LUA" >/dev/null 2>&1; then
    printf 'tests/run.sh: requested Lua executable unavailable: %s\n' "$LUA" >&2
    exit 127
  fi
elif command -v luajit >/dev/null 2>&1; then
  LUA=luajit
elif command -v lua >/dev/null 2>&1; then
  LUA=lua
else
  echo "tests/run.sh: no Lua interpreter found; set LUA to an executable" >&2
  exit 127
fi
printf 'Lua runtime: %s\n' "$(command -v "$LUA")"
"$LUA" -v
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/hansel-tests.XXXXXX")"
mkdir "$SCRATCH/http-preservation" "$SCRATCH/library-download-preservation"
printf 'Preservation scratch: %s\n' "$SCRATCH"
"$LUA" tests/test_origin.lua
"$LUA" tests/test_obfuscate.lua
"$LUA" tests/test_http.lua
"$LUA" tests/test_http_preservation.lua "$ROOT" "$SCRATCH/http-preservation"
"$LUA" tests/test_settings.lua
"$LUA" tests/test_migrate.lua
"$LUA" tests/test_cache_scope.lua
"$LUA" tests/test_opds.lua
"$LUA" tests/test_session.lua
"$LUA" tests/test_catalog_library.lua
"$LUA" tests/test_library_download_preservation.lua "$ROOT" "$SCRATCH/library-download-preservation"
"$LUA" tests/test_paging.lua
"$LUA" tests/test_nav.lua
"$LUA" tests/test_manifest.lua
"$LUA" tests/test_kosync_client.lua
"$LUA" tests/test_progress_sync.lua
"$LUA" tests/test_background.lua
"$LUA" tests/test_search.lua
"$LUA" tests/test_boot_io.lua
"$LUA" tests/test_ui.lua
echo "all tests passed"
