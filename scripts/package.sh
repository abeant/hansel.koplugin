#!/bin/sh
# Build hansel.koplugin.zip with a top-level hansel.koplugin/ folder.
# Plugin sources stay at the repo root; the wrapper exists only in the zip.
set -e
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="${1:-$ROOT/hansel.koplugin.zip}"
case "$OUT" in
    /*) ;;
    *) OUT="$ROOT/$OUT" ;;
esac

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hansel-pack.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/hansel.koplugin"
mkdir -p "$DEST"

copy_item() {
    local src="$1"
    if [ ! -e "$src" ]; then
        echo "package.sh: missing $src" >&2
        exit 1
    fi
    cp -R "$src" "$DEST/"
}

copy_item _meta.lua
copy_item main.lua
copy_item LICENSE
copy_item README.md
copy_item hansel.svg
copy_item assets
copy_item fonts
copy_item lib
copy_item ui

rm -f "$OUT"
( cd "$STAGE" && zip -r -q "$OUT" hansel.koplugin )
echo "wrote $OUT"

# Fail if the zip is not rooted at hansel.koplugin/
first="$(unzip -Z -1 "$OUT" | head -n 1)"
case "$first" in
    hansel.koplugin/*|hansel.koplugin) ;;
    *)
        echo "package.sh: zip top entry is '$first', expected hansel.koplugin/" >&2
        exit 1
        ;;
esac
