#!/usr/bin/env bash
# install.sh — Install ShotPaste from GitHub Releases
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/shotpaste/shotpaste/main/scripts/install.sh | bash
#   VERSION=1.2.3 bash scripts/install.sh
#
# The script downloads the DMG from GitHub Releases, mounts it,
# copies ShotPaste.app to /Applications, and cleans up.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

has_color() {
  [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 || "${FORCE_COLOR:-}" == "1" ]]
}

if has_color; then
  BOLD='\033[1m'
  GREEN='\033[1;32m'
  CYAN='\033[1;36m'
  RED='\033[1;31m'
  YELLOW='\033[1;33m'
  RESET='\033[0m'
else
  BOLD='' GREEN='' CYAN='' RED='' YELLOW='' RESET=''
fi

info()  { printf "${CYAN}▸${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}✔${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠${RESET} %s\n" "$*" >&2; }
fail()  { printf "${RED}✖${RESET} %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || fail "ShotPaste is a macOS app. This script only works on macOS."

for cmd in curl hdiutil shasum; do
  command -v "$cmd" &>/dev/null || fail "Required command not found: $cmd"
done

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------

REPO="shotpaste/shotpaste"

is_stable_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

is_newer_version() {
  local candidate="$1" current="$2"
  local candidate_major candidate_minor candidate_patch
  local current_major current_minor current_patch
  IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$candidate"
  IFS=. read -r current_major current_minor current_patch <<< "$current"

  (( candidate_major > current_major )) ||
    (( candidate_major == current_major && candidate_minor > current_minor )) ||
    (( candidate_major == current_major && candidate_minor == current_minor && candidate_patch > current_patch ))
}

if [[ -z "${VERSION:-}" ]]; then
  info "Fetching latest macOS release version…"
  releases_json=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=100")
  latest_version=""
  while IFS= read -r candidate_tag; do
    candidate_version="${candidate_tag#macos-v}"
    if is_stable_version "$candidate_version" &&
      { [[ -z "$latest_version" ]] || is_newer_version "$candidate_version" "$latest_version"; }; then
      latest_version="$candidate_version"
    fi
  done < <(
    printf '%s' "$releases_json" \
      | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"macos-v[^"]+"' \
      | sed -E 's/.*"(macos-v[^"]+)"/\1/'
  )
  VERSION="$latest_version"
  [[ -n "$VERSION" ]] || fail "Could not determine the latest macOS release version."
else
  VERSION="${VERSION#macos-v}"
  VERSION="${VERSION#v}"
fi

is_stable_version "$VERSION" || fail "VERSION must use MAJOR.MINOR.PATCH."
TAG="macos-v${VERSION}"

DMG_NAME="ShotPaste-v${VERSION}-macOS-arm64.dmg"
CHECKSUM_NAME="SHA256SUMS.txt"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_NAME}"
CHECKSUM_URL="https://github.com/${REPO}/releases/download/${TAG}/${CHECKSUM_NAME}"

printf "\n${BOLD}ShotPaste Installer${RESET}  •  v%s\n\n" "$VERSION"

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

TMPDIR_INSTALL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

DMG_PATH="${TMPDIR_INSTALL}/${DMG_NAME}"
CHECKSUM_PATH="${TMPDIR_INSTALL}/${CHECKSUM_NAME}"

info "Downloading ${DMG_NAME}…"
if ! curl -fSL --progress-bar -o "$DMG_PATH" "$DOWNLOAD_URL"; then
  fail "Download failed. Check the version number and your network connection."
fi
ok "Downloaded ${DMG_NAME}"

info "Downloading ${CHECKSUM_NAME}…"
curl -fSL --progress-bar -o "$CHECKSUM_PATH" "$CHECKSUM_URL" \
  || fail "Checksum download failed."

expected_hash=$(awk -v file="$DMG_NAME" '$2 == file { print $1; exit }' "$CHECKSUM_PATH")
[[ "$expected_hash" =~ ^[[:xdigit:]]{64}$ ]] \
  || fail "${DMG_NAME} is not listed in ${CHECKSUM_NAME}."

info "Verifying SHA-256 checksum…"
printf '%s  %s\n' "$expected_hash" "$DMG_PATH" | shasum -a 256 -c - >/dev/null \
  || fail "SHA-256 verification failed."
ok "Checksum verified"

info "Verifying disk image…"
hdiutil verify "$DMG_PATH" >/dev/null || fail "Disk image verification failed."
ok "Disk image verified"

# ---------------------------------------------------------------------------
# Mount, copy, unmount
# ---------------------------------------------------------------------------

MOUNT_POINT="${TMPDIR_INSTALL}/shotpaste-dmg"
mkdir -p "$MOUNT_POINT"

info "Mounting disk image…"
hdiutil attach "$DMG_PATH" -nobrowse -quiet -mountpoint "$MOUNT_POINT" \
  || fail "Failed to mount the DMG."

INSTALL_DIR="/Applications"

info "Copying ShotPaste.app to ${INSTALL_DIR}…"

# Remove existing installation if present
if [[ -d "${INSTALL_DIR}/ShotPaste.app" ]]; then
  warn "Existing ShotPaste.app found — replacing."
  rm -rf "${INSTALL_DIR}/ShotPaste.app"
fi

ditto "${MOUNT_POINT}/ShotPaste.app" "${INSTALL_DIR}/ShotPaste.app" \
  || fail "Failed to copy ShotPaste.app. You may need to run with sudo."

info "Unmounting disk image…"
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true

ok "Installed ShotPaste.app to ${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# Post-install
# ---------------------------------------------------------------------------

printf "\n${GREEN}${BOLD}Installation complete!${RESET}\n\n"
printf "  Launch ShotPaste from your Applications folder or Spotlight.\n"
printf "  Current releases use ShotPaste's persistent self-signed certificate.\n"
printf "  If Gatekeeper blocks launch, follow START-HERE-macOS.txt from the DMG.\n"
printf "  On first launch, grant ${BOLD}Screen Recording${RESET} permission when prompted.\n\n"
