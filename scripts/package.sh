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
copy_item CHANGELOG.md
copy_item hansel.svg
copy_item hansel-dark.svg
copy_item assets
copy_item fonts
copy_item lib
copy_item ui

# Build and validate in the temporary stage before replacing the destination.
# Explicitly omit Finder metadata; never include settings or device caches.
ARCHIVE="$STAGE/hansel.koplugin.zip"
( cd "$STAGE" && zip -r -q "$ARCHIVE" hansel.koplugin -x '*/.DS_Store' '*/._*' )
unzip -tq "$ARCHIVE" >/dev/null
unzip -Z -1 "$ARCHIVE" > "$STAGE/entries"
if grep -v '^hansel\.koplugin/' "$STAGE/entries" >/dev/null; then
    echo "package.sh: zip contains an entry outside hansel.koplugin/" >&2
    exit 1
fi
for required in _meta.lua main.lua LICENSE README.md CHANGELOG.md hansel.svg hansel-dark.svg assets/hansel.png; do
    if ! grep -Fx "hansel.koplugin/$required" "$STAGE/entries" >/dev/null; then
        echo "package.sh: zip is missing $required" >&2
        exit 1
    fi
done
mv -f "$ARCHIVE" "$OUT"
echo "wrote $OUT"
