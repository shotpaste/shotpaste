#!/usr/bin/env bash
# install.sh — Install Lite Screen from GitHub Releases
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ahtcfg24/LiteScreen/master/scripts/install.sh | bash
#   VERSION=1.2.3 bash scripts/install.sh
#
# The script downloads the DMG from GitHub Releases, mounts it,
# copies Lite Screen.app to /Applications, and cleans up.

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

[[ "$(uname -s)" == "Darwin" ]] || fail "Lite Screen is a macOS app. This script only works on macOS."

for cmd in curl hdiutil shasum; do
  command -v "$cmd" &>/dev/null || fail "Required command not found: $cmd"
done

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------

REPO="ahtcfg24/LiteScreen"

if [[ -z "${VERSION:-}" ]]; then
  info "Fetching latest release version…"
  VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' \
    | head -1 \
    | sed -E 's/.*"v([^"]+)".*/\1/')
  [[ -n "$VERSION" ]] || fail "Could not determine the latest release version."
fi

# Strip leading "v" if present
VERSION="${VERSION#v}"

DMG_NAME="LiteScreen-v${VERSION}-macOS-arm64.dmg"
CHECKSUM_NAME="SHA256SUMS.txt"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${DMG_NAME}"
CHECKSUM_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${CHECKSUM_NAME}"

printf "\n${BOLD}Lite Screen Installer${RESET}  •  v%s\n\n" "$VERSION"

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

MOUNT_POINT="${TMPDIR_INSTALL}/lite-screen-dmg"
mkdir -p "$MOUNT_POINT"

info "Mounting disk image…"
hdiutil attach "$DMG_PATH" -nobrowse -quiet -mountpoint "$MOUNT_POINT" \
  || fail "Failed to mount the DMG."

INSTALL_DIR="/Applications"

info "Copying Lite Screen.app to ${INSTALL_DIR}…"

# Remove existing installation if present
if [[ -d "${INSTALL_DIR}/Lite Screen.app" ]]; then
  warn "Existing Lite Screen.app found — replacing."
  rm -rf "${INSTALL_DIR}/Lite Screen.app"
fi

ditto "${MOUNT_POINT}/Lite Screen.app" "${INSTALL_DIR}/Lite Screen.app" \
  || fail "Failed to copy Lite Screen.app. You may need to run with sudo."

info "Unmounting disk image…"
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true

ok "Installed Lite Screen.app to ${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# Post-install
# ---------------------------------------------------------------------------

printf "\n${GREEN}${BOLD}Installation complete!${RESET}\n\n"
printf "  Launch Lite Screen from your Applications folder or Spotlight.\n"
printf "  Current releases are self-signed and not Apple-notarized.\n"
printf "  If Gatekeeper blocks launch, follow START-HERE-macOS.txt from the DMG.\n"
printf "  On first launch, grant ${BOLD}Screen Recording${RESET} permission when prompted.\n\n"
