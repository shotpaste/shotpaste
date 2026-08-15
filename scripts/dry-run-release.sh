#!/usr/bin/env bash
# Build, stably sign, and package the single canonical local Release product.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/.build/macos/Release/ShotPaste.app"
OUTPUT_DIR="$ROOT_DIR/build/local-release"
DMG_PATH="$OUTPUT_DIR/ShotPaste-local-macOS-arm64.dmg"

[[ "$(uname -s)" == "Darwin" ]] || {
  printf "error: This script only supports macOS.\n" >&2
  exit 1
}

SHOTPASTE_LOCAL_RELEASE_COMPILER_WORKAROUND=1 \
  "$ROOT_DIR/scripts/build_and_run.sh" build --configuration Release "$@"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_PATH" 2>&1)"
[[ "$DESIGNATED_REQUIREMENT" != *"cdhash"* ]] || {
  printf "error: Refusing to package an unstable ad-hoc signature.\n" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"
while IFS= read -r -d '' old_dmg; do
  rm -f -- "$old_dmg"
done < <(/usr/bin/find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.dmg' -print0)

"$ROOT_DIR/scripts/create-macos-dmg.sh" \
  "$APP_PATH" \
  "$DMG_PATH" \
  "ShotPaste Local" \
  "local"

DMG_COUNT="$(/usr/bin/find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.dmg' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$DMG_COUNT" == "1" ]] || {
  printf "error: Expected one local macOS DMG, found %s.\n" "$DMG_COUNT" >&2
  exit 1
}

printf "success: Canonical Release app: %s\n" "$APP_PATH"
printf "success: Single local macOS DMG: %s\n" "$DMG_PATH"
