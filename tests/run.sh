#!/bin/sh
set -e
cd "$(dirname "$0")/.."
LUA="${LUA:-luajit}"
if ! command -v "$LUA" >/dev/null 2>&1; then
  LUA=lua
fi
"$LUA" tests/test_origin.lua
"$LUA" tests/test_obfuscate.lua
"$LUA" tests/test_http.lua
"$LUA" tests/test_settings.lua
"$LUA" tests/test_migrate.lua
"$LUA" tests/test_cache_scope.lua
"$LUA" tests/test_opds.lua
"$LUA" tests/test_session.lua
"$LUA" tests/test_catalog_library.lua
"$LUA" tests/test_nav.lua
"$LUA" tests/test_manifest.lua
"$LUA" tests/test_kosync_client.lua
"$LUA" tests/test_progress_sync.lua
"$LUA" tests/test_background.lua
"$LUA" tests/test_search.lua
"$LUA" tests/test_boot_io.lua
"$LUA" tests/test_ui.lua
echo "all tests passed"
