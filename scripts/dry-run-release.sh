#!/usr/bin/env bash
# Build, stably sign, and package the single canonical local Release product.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/.build/macos/Release/Lite Screen.app"
OUTPUT_DIR="$ROOT_DIR/build/local-release"
DMG_PATH="$OUTPUT_DIR/LiteScreen-local-macOS-arm64.dmg"
STAGING_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

[[ "$(uname -s)" == "Darwin" ]] || {
  printf "error: This script only supports macOS.\n" >&2
  exit 1
}

LITESCREEN_LOCAL_RELEASE_COMPILER_WORKAROUND=1 \
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

ditto "$APP_PATH" "$STAGING_DIR/Lite Screen.app"
ln -s /Applications "$STAGING_DIR/Applications"
sed 's/@VERSION@/local/g' "$ROOT_DIR/docs/release/START-HERE-macOS.txt" \
  > "$STAGING_DIR/START-HERE-macOS.txt"

hdiutil create \
  -volname "Lite Screen Local" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"
hdiutil verify "$DMG_PATH"

DMG_COUNT="$(/usr/bin/find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.dmg' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$DMG_COUNT" == "1" ]] || {
  printf "error: Expected one local macOS DMG, found %s.\n" "$DMG_COUNT" >&2
  exit 1
}

printf "success: Canonical Release app: %s\n" "$APP_PATH"
printf "success: Single local macOS DMG: %s\n" "$DMG_PATH"
