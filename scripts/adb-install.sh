#!/bin/sh
# Push hansel.koplugin onto a USB-connected Android KOReader install.
# Does not run unless you invoke it; default destination is the shared plugins dir.
set -e
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DEST="${1:-/sdcard/koreader/plugins/hansel.koplugin}"
PKG="${KOREADER_PACKAGE:-org.koreader.launcher}"

if ! command -v adb >/dev/null 2>&1; then
    echo "adb-install.sh: adb not on PATH" >&2
    exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hansel-adb.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
"$ROOT/scripts/package.sh" "$STAGE/hansel.koplugin.zip"
unzip -q "$STAGE/hansel.koplugin.zip" -d "$STAGE"

adb push "$STAGE/hansel.koplugin/." "$DEST/"
adb shell am force-stop "$PKG" || true
echo "installed $DEST"
