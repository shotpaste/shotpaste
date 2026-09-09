#!/usr/bin/env bash
# Build, stably sign, and package the single canonical local Release product.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/.build/macos/Release/ShotPaste.app"
OUTPUT_DIR="$ROOT_DIR/build/local-release"

[[ "$(uname -s)" == "Darwin" ]] || {
  printf "error: This script only supports macOS.\n" >&2
  exit 1
}

SHOTPASTE_LOCAL_RELEASE_COMPILER_WORKAROUND=1 \
  SHOTPASTE_MACOS_ARCH="${SHOTPASTE_MACOS_ARCH:-$(uname -m)}" \
  "$ROOT_DIR/scripts/build_and_run.sh" build --configuration Release "$@"

PACKAGE_ARCH="$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/ShotPaste")"
case "$PACKAGE_ARCH" in
  arm64|x86_64) ;;
  *) printf "error: Select one architecture with --arch arm64 or --arch x86_64.\n" >&2; exit 1 ;;
esac
DMG_PATH="$OUTPUT_DIR/ShotPaste-local-macOS-${PACKAGE_ARCH}.dmg"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_PATH" 2>&1)"
[[ "$DESIGNATED_REQUIREMENT" != *"cdhash"* ]] || {
  printf "error: Refusing to package an unstable ad-hoc signature.\n" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"

"$ROOT_DIR/scripts/create-macos-dmg.sh" \
  "$APP_PATH" \
  "$DMG_PATH" \
  "ShotPaste Local" \
  "local"

printf "success: Canonical Release app: %s\n" "$APP_PATH"
printf "success: Local %s macOS DMG: %s\n" "$PACKAGE_ARCH" "$DMG_PATH"
