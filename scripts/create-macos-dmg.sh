#!/usr/bin/env bash
# Create the canonical drag-to-Applications macOS disk image.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  printf 'Usage: %s APP_PATH OUTPUT_DMG VOLUME_NAME VERSION\n' "$0"
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[[ $# -eq 4 ]] || {
  usage >&2
  exit 2
}

APP_PATH="$1"
OUTPUT_DMG="$2"
VOLUME_NAME="$3"
VERSION="$4"

[[ "$(uname -s)" == "Darwin" ]] || fail "This script only supports macOS."
[[ -d "$APP_PATH" && "$APP_PATH" == *.app ]] || fail "APP_PATH must be an existing .app bundle."
[[ "$OUTPUT_DMG" == *.dmg ]] || fail "OUTPUT_DMG must end in .dmg."
[[ -n "$VOLUME_NAME" ]] || fail "VOLUME_NAME must not be empty."
[[ -n "$VERSION" ]] || fail "VERSION must not be empty."

for command_name in codesign hdiutil osascript swift; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
done

mkdir -p "$(dirname "$OUTPUT_DMG")"
OUTPUT_DIRECTORY="$(cd "$(dirname "$OUTPUT_DMG")" && pwd -P)"
OUTPUT_DMG="$OUTPUT_DIRECTORY/$(basename "$OUTPUT_DMG")"

# Rebuilding a locally opened image otherwise leaves its old volume mounted.
# Finder can then apply the layout to that stale volume instead of the new RW
# image because both have the same display name. Eject only mounts whose source
# image is the exact output path being replaced.
while IFS= read -r existing_mount_point; do
  [[ -n "$existing_mount_point" ]] || continue
  printf 'info: Ejecting previously mounted output image at %s\n' "$existing_mount_point"
  hdiutil detach "$existing_mount_point" -quiet \
    || fail "Unable to eject the previously mounted output image."
done < <(
  hdiutil info | awk -v target="$OUTPUT_DMG" '
    /^image-path/ {
      imagePath = $0
      sub(/^[^:]*:[[:space:]]*/, "", imagePath)
      matchesOutput = (imagePath == target)
      next
    }
    matchesOutput && match($0, /\/Volumes\//) {
      print substr($0, RSTART)
    }
  '
)

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shotpaste-dmg.XXXXXX")"
STAGING_DIR="$WORK_DIR/root"
STAGED_APP_PATH="$STAGING_DIR/ShotPaste.app"
RESOURCE_DIR="$STAGED_APP_PATH/Contents/Resources"
MOUNT_POINT=""
MOUNT_DEVICE=""
VERIFY_MOUNT_POINT="$WORK_DIR/verify"
RW_DMG="$WORK_DIR/layout-rw.dmg"
BACKGROUND_NAME="ShotPasteDMGBackground.png"
BACKGROUND_PATH="$RESOURCE_DIR/$BACKGROUND_NAME"
IS_MOUNTED=0
IS_VERIFY_MOUNTED=0

cleanup() {
  if [[ "$IS_VERIFY_MOUNTED" -eq 1 ]]; then
    hdiutil detach "$VERIFY_MOUNT_POINT" -quiet 2>/dev/null || true
  fi
  if [[ "$IS_MOUNTED" -eq 1 ]]; then
    hdiutil detach "${MOUNT_POINT:-$MOUNT_DEVICE}" -quiet 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$VERIFY_MOUNT_POINT"
ditto "$APP_PATH" "$STAGED_APP_PATH"
mkdir -p "$RESOURCE_DIR"
ln -s /Applications "$STAGING_DIR/Applications"
sed "s/@VERSION@/$VERSION/g" "$ROOT_DIR/docs/release/START-HERE-macOS.txt" \
  > "$RESOURCE_DIR/ShotPasteInstallationGuide.txt"
cp "$ROOT_DIR/LICENSE" "$RESOURCE_DIR/LICENSE.txt"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCE_DIR/ThirdPartyNotices.md"
swift "$ROOT_DIR/scripts/generate-dmg-background.swift" "$BACKGROUND_PATH" "$VERSION"

# The background lives inside the app so the DMG root has no support folder to
# reveal when Finder's “Show All Files” setting is enabled. Re-sign the staged
# copy with the same stable identity after adding the installer-only resources.
APP_VARIANT="$(/usr/libexec/PlistBuddy -c 'Print :ShotPasteVariant' "$STAGED_APP_PATH/Contents/Info.plist")"
case "$APP_VARIANT" in
  debug) APP_CONFIGURATION="Debug" ;;
  release) APP_CONFIGURATION="Release" ;;
  *) fail "Unexpected ShotPaste app variant: $APP_VARIANT" ;;
esac
"$ROOT_DIR/scripts/sign-macos-app.sh" "$STAGED_APP_PATH" "$APP_CONFIGURATION"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT_DEVICE="$(
  printf '%s\n' "$ATTACH_OUTPUT" \
    | awk 'match($0, /\/Volumes\//) { device = $1 } END { print device }'
)"
MOUNT_POINT="$(
  printf '%s\n' "$ATTACH_OUTPUT" \
    | awk 'match($0, /\/Volumes\//) { mount = substr($0, RSTART) } END { print mount }'
)"
IS_MOUNTED=1
[[ -n "$MOUNT_DEVICE" && -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] \
  || fail "Unable to resolve the writable DMG mount point."

/usr/bin/osascript \
  - "$MOUNT_POINT" "$MOUNT_POINT/ShotPaste.app/Contents/Resources/$BACKGROUND_NAME" \
  <<'APPLESCRIPT'
on run arguments
  set mountPath to item 1 of arguments
  set backgroundPath to item 2 of arguments
  set volumeAlias to POSIX file mountPath as alias
  set backgroundAlias to POSIX file backgroundPath as alias

  tell application "Finder"
    set targetDisk to disk of volumeAlias
    tell targetDisk
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set pathbar visible of container window to false
      set bounds of container window to {180, 120, 840, 540}

      set viewOptions to icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 104
      set text size of viewOptions to 13
      set background picture of viewOptions to backgroundAlias

      set position of item "ShotPaste.app" of container window to {175, 225}
      set position of item "Applications" of container window to {485, 225}

      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
APPLESCRIPT

[[ -f "$MOUNT_POINT/.DS_Store" ]] || fail "Finder did not persist the custom DMG layout."
sync

# Writable HFS+ mounts may create event-tracking metadata while Finder lays out
# the window. It serves no purpose in the final read-only installer image and
# becomes visible for users who show hidden files.
rm -rf "$MOUNT_POINT/.fseventsd"
hdiutil detach "$MOUNT_POINT" -quiet
IS_MOUNTED=0

rm -f "$OUTPUT_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG" >/dev/null
hdiutil verify "$OUTPUT_DMG" >/dev/null

hdiutil attach \
  "$OUTPUT_DMG" \
  -readonly \
  -nobrowse \
  -noverify \
  -mountpoint "$VERIFY_MOUNT_POINT" \
  -quiet
IS_VERIFY_MOUNTED=1

[[ -d "$VERIFY_MOUNT_POINT/ShotPaste.app" ]] || fail "DMG is missing ShotPaste.app."
[[ -L "$VERIFY_MOUNT_POINT/Applications" ]] || fail "DMG is missing the Applications link."
[[ "$(readlink "$VERIFY_MOUNT_POINT/Applications")" == "/Applications" ]] \
  || fail "DMG Applications link has an unexpected target."
[[ -f "$VERIFY_MOUNT_POINT/ShotPaste.app/Contents/Resources/ShotPasteInstallationGuide.txt" ]] \
  || fail "DMG is missing its installation guide."
[[ -f "$VERIFY_MOUNT_POINT/ShotPaste.app/Contents/Resources/LICENSE.txt" ]] \
  || fail "DMG is missing its license."
[[ -f "$VERIFY_MOUNT_POINT/ShotPaste.app/Contents/Resources/ThirdPartyNotices.md" ]] \
  || fail "DMG is missing its third-party notices."
[[ -f "$VERIFY_MOUNT_POINT/ShotPaste.app/Contents/Resources/$BACKGROUND_NAME" ]] \
  || fail "DMG is missing its visual background."
[[ -f "$VERIFY_MOUNT_POINT/.DS_Store" ]] || fail "DMG is missing its custom Finder layout."
[[ ! -e "$VERIFY_MOUNT_POINT/.fseventsd" ]] || fail "DMG contains writable-mount event metadata."
codesign --verify --deep --strict "$VERIFY_MOUNT_POINT/ShotPaste.app"

hdiutil detach "$VERIFY_MOUNT_POINT" -quiet
IS_VERIFY_MOUNTED=0

printf 'success: Drag-to-Applications DMG: %s\n' "$OUTPUT_DMG"
