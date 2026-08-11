#!/usr/bin/env bash
# Sign a Lite Screen app with a certificate-backed identity and reject ad-hoc output.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-}"
CONFIGURATION="${2:-Release}"
ENTITLEMENTS_SOURCE="${LITESCREEN_ENTITLEMENTS_PATH:-$ROOT_DIR/platforms/mac/LiteScreen/LiteScreen.entitlements}"
KEYCHAIN_PATH="${LITESCREEN_KEYCHAIN_PATH:-}"
ALLOW_UNTRUSTED_SELF_SIGNED="${LITESCREEN_ALLOW_UNTRUSTED_SELF_SIGNED:-0}"

fail() {
  printf "error: %s\n" "$1" >&2
  exit 1
}

info() {
  printf "info: %s\n" "$1"
}

usage() {
  cat <<'USAGE'
Usage: scripts/sign-macos-app.sh <app-path> [Debug|Release]

The script requires a certificate-backed code-signing identity. Set
LITESCREEN_CODESIGN_IDENTITY to an identity hash/name, or let the script select
a Lite Screen local-development, fixed release, Apple Development, or Developer
ID identity.
Ad-hoc signing is intentionally rejected because it changes macOS privacy identity.
USAGE
}

if [[ -z "$APP_PATH" || "$APP_PATH" == "--help" || "$APP_PATH" == "-h" ]]; then
  usage
  [[ -n "$APP_PATH" ]] && exit 0
  exit 1
fi

[[ "$(uname -s)" == "Darwin" ]] || fail "This script only supports macOS."
[[ -d "$APP_PATH" ]] || fail "App bundle not found: $APP_PATH"
[[ -f "$APP_PATH/Contents/Info.plist" ]] || fail "App Info.plist not found: $APP_PATH"
[[ -f "$ENTITLEMENTS_SOURCE" ]] || fail "Entitlements file not found: $ENTITLEMENTS_SOURCE"
command -v codesign >/dev/null 2>&1 || fail "codesign is required."
command -v security >/dev/null 2>&1 || fail "security is required."

identity_listing() {
  if [[ "$ALLOW_UNTRUSTED_SELF_SIGNED" == "1" ]]; then
    if [[ -n "$KEYCHAIN_PATH" ]]; then
      security find-identity -p basic "$KEYCHAIN_PATH"
    else
      security find-identity -p basic
    fi
  elif [[ -n "$KEYCHAIN_PATH" ]]; then
    security find-identity -v -p codesigning "$KEYCHAIN_PATH"
  else
    security find-identity -v -p codesigning
  fi
}

identity_hash_matching() {
  local needle="$1"
  identity_listing | /usr/bin/awk -v needle="$needle" '
    index($0, needle) && $2 ~ /^[[:xdigit:]]{40}$/ { print $2; exit }
  '
}

SIGN_IDENTITY="${LITESCREEN_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if [[ "$CONFIGURATION" == "Release" ]]; then
    for pattern in "Developer ID Application:" "Lite Screen Self-Signed" "Lite Screen Local Development" "LiteScreen Self-Signed" "Apple Development:"; do
      SIGN_IDENTITY="$(identity_hash_matching "$pattern")"
      [[ -n "$SIGN_IDENTITY" ]] && break
    done
  else
    for pattern in "Lite Screen Local Development" "Lite Screen Self-Signed" "LiteScreen Self-Signed" "Apple Development:" "Developer ID Application:"; do
      SIGN_IDENTITY="$(identity_hash_matching "$pattern")"
      [[ -n "$SIGN_IDENTITY" ]] && break
    done
  fi
fi

[[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]] || fail \
  "No stable code-signing identity is available. Run scripts/create-signing-cert.sh once or set LITESCREEN_CODESIGN_IDENTITY."

IDENTITY_LINE="$(identity_listing | /usr/bin/grep -F "$SIGN_IDENTITY" | /usr/bin/head -1 || true)"
[[ -n "$IDENTITY_LINE" ]] || fail "The configured code-signing identity is not available in the selected keychain."

TIMESTAMP_MODE="${LITESCREEN_CODESIGN_TIMESTAMP:-auto}"
case "$TIMESTAMP_MODE" in
  auto)
    if [[ "$IDENTITY_LINE" == *"Developer ID Application:"* ]]; then
      TIMESTAMP_ARGS=(--timestamp)
    else
      TIMESTAMP_ARGS=(--timestamp=none)
    fi
    ;;
  required)
    TIMESTAMP_ARGS=(--timestamp)
    ;;
  none)
    TIMESTAMP_ARGS=(--timestamp=none)
    ;;
  *)
    fail "LITESCREEN_CODESIGN_TIMESTAMP must be auto, required, or none."
    ;;
esac

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
EXPECTED_BUNDLE_ID="${LITESCREEN_EXPECTED_BUNDLE_ID:-}"
if [[ -z "$EXPECTED_BUNDLE_ID" ]]; then
  if [[ "$CONFIGURATION" == "Debug" ]]; then
    EXPECTED_BUNDLE_ID="com.ahtcfg24.litescreen.debug"
  else
    EXPECTED_BUNDLE_ID="com.ahtcfg24.litescreen"
  fi
fi
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail \
  "Unexpected bundle identifier '$BUNDLE_ID'; expected '$EXPECTED_BUNDLE_ID'."

SIGNING_DIR="$ROOT_DIR/.build/macos/signing"
CONFIGURATION_SLUG="$(printf '%s' "$CONFIGURATION" | /usr/bin/tr '[:upper:]' '[:lower:]')"
PROCESSED_ENTITLEMENTS="$SIGNING_DIR/${CONFIGURATION_SLUG}-entitlements.plist"
mkdir -p "$SIGNING_DIR"
rm -f "$PROCESSED_ENTITLEMENTS"
/usr/bin/plutil -convert xml1 -o "$PROCESSED_ENTITLEMENTS" "$ENTITLEMENTS_SOURCE"

if [[ "$CONFIGURATION" == "Debug" ]]; then
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$PROCESSED_ENTITLEMENTS" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$PROCESSED_ENTITLEMENTS"
fi

sign_code() {
  if [[ -n "$KEYCHAIN_PATH" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" \
      --options runtime "${TIMESTAMP_ARGS[@]}" "$1"
  else
    codesign --force --sign "$SIGN_IDENTITY" \
      --options runtime "${TIMESTAMP_ARGS[@]}" "$1"
  fi
}

info "Signing $CONFIGURATION app with a stable certificate-backed identity."
/usr/bin/xattr -rc "$APP_PATH"

# Sign loose Mach-O helpers and dynamic libraries first. The main executable is
# signed when the outer app bundle is signed below.
while IFS= read -r code_path; do
  [[ "$code_path" == "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" ]] && continue
  if /usr/bin/file -b "$code_path" | /usr/bin/grep -q 'Mach-O'; then
    sign_code "$code_path"
  fi
done < <(/usr/bin/find "$APP_PATH/Contents" -type f -print)

# Sign nested code bundles from deepest to shallowest so every parent seals its
# already-signed children.
while IFS= read -r nested_bundle; do
  [[ -z "$nested_bundle" ]] && continue
  sign_code "$nested_bundle"
done < <(
  /usr/bin/find "$APP_PATH/Contents" -type d \( \
    -name '*.app' -o -name '*.appex' -o -name '*.framework' -o -name '*.xpc' \
  \) -print \
    | /usr/bin/awk '{ print length($0) "\t" $0 }' \
    | /usr/bin/sort -rn \
    | /usr/bin/cut -f2-
)

if [[ -n "$KEYCHAIN_PATH" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN_PATH" --options runtime \
    --entitlements "$PROCESSED_ENTITLEMENTS" \
    "${TIMESTAMP_ARGS[@]}" \
    "$APP_PATH"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime \
    --entitlements "$PROCESSED_ENTITLEMENTS" \
    "${TIMESTAMP_ARGS[@]}" \
    "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

SIGNED_IDENTIFIER="$(codesign -d --verbose=4 "$APP_PATH" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p' | /usr/bin/head -1)"
[[ "$SIGNED_IDENTIFIER" == "$BUNDLE_ID" ]] || fail \
  "Signed identifier '$SIGNED_IDENTIFIER' does not match bundle identifier '$BUNDLE_ID'."

DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_PATH" 2>&1)"
[[ "$DESIGNATED_REQUIREMENT" != *"cdhash"* ]] || fail \
  "The signed app still has a cdhash-only designated requirement; refusing unstable ad-hoc output."

info "Signature verified; the designated requirement is certificate-backed and stable across rebuilds."
