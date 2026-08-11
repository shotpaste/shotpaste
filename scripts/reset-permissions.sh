#!/usr/bin/env bash
# reset-permissions.sh — Reset all TCC permissions for ShotPaste
#
# Usage:
#   ./scripts/reset-permissions.sh           # Interactive mode (asks for confirmation)
#   ./scripts/reset-permissions.sh --force   # Skip confirmation
#

set -euo pipefail

APP_NAME="ShotPaste"
APP_PROCESS="ShotPaste"
APP_PATH="/Applications/ShotPaste.app"
FALLBACK_BUNDLE_ID="com.ahtcfg24.shotpaste"

# ─── Auto-detect bundle ID from app name ─────────────────────────
resolve_bundle_id() {
  local detected=""

  # Method 1: Ask LaunchServices via osascript
  detected=$(osascript -e "id of app \"$APP_NAME\"" 2>/dev/null || true)
  if [[ -n "$detected" ]]; then
    echo "$detected"
    return
  fi

  # Method 2: Read directly from the .app bundle's Info.plist
  if [ -d "$APP_PATH" ]; then
    detected=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
    if [[ -n "$detected" ]]; then
      echo "$detected"
      return
    fi
  fi

  # Fallback: hardcoded
  echo "$FALLBACK_BUNDLE_ID"
}

# ─── Resolve installed app version ───────────────────────────────
resolve_app_version() {
  local version=""

  # Method 1: Read from the installed app's Info.plist using PlistBuddy
  if [ -d "$APP_PATH" ]; then
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
    if [[ -n "$version" ]]; then
      echo "v$version"
      return
    fi
  fi

  # Method 2: Read using defaults command
  if [ -d "$APP_PATH" ]; then
    version=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
    if [[ -n "$version" ]]; then
      echo "v$version"
      return
    fi
  fi

  # Fallback: empty
  echo ""
}

BUNDLE_ID=$(resolve_bundle_id)
APP_VERSION=$(resolve_app_version)
VERSION_DISPLAY=""
if [[ -n "$APP_VERSION" ]]; then
  VERSION_DISPLAY=" $APP_VERSION"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}→${NC} $*"; }
success() { echo -e "${GREEN}✅${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠️${NC}  $*"; }
error()   { echo -e "${RED}❌${NC} $*"; }

# Print a line padded to fit exactly inside the 54-cell box.
print_box_line() {
  local content="$1"
  local color="${2:-$YELLOW}"
  local target_width=54
  local content_len=${#content}

  if [[ "$content" == *"⚠️"* || "$content" == *"✅"* ]]; then
    content_len=$((content_len + 1))
  fi

  local padding_len=$((target_width - content_len))
  local padding=""
  if (( padding_len > 0 )); then
    padding=$(printf "%${padding_len}s" "")
  fi

  echo -e "${color}║${content}${padding}║${NC}"
}

# ─── Confirmation ────────────────────────────────────────────────
if [[ "${1:-}" != "--force" ]]; then
  echo ""
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
  print_box_line "  ⚠️  RESET PERMISSIONS: ${APP_NAME}${VERSION_DISPLAY}" "$YELLOW"
  echo -e "${YELLOW}╠══════════════════════════════════════════════════════╣${NC}"
  print_box_line "  This will:" "$YELLOW"
  print_box_line "  • Reset ALL TCC permissions for ${APP_NAME}" "$YELLOW"
  print_box_line "  • Require you to re-grant permissions on next launch" "$YELLOW"
  print_box_line "  • NOT delete the app or your settings" "$YELLOW"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  read -rp "Are you sure? Type 'yes' to proceed: " confirm < /dev/tty
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""
fi

info "Detected bundle ID: ${BUNDLE_ID}"
echo ""

# ─── 1. Kill running app ────────────────────────────────────────
info "Stopping $APP_NAME before resetting permissions..."
killall "$APP_PROCESS" 2>/dev/null && success "App stopped" || info "App was not running"
sleep 1

# ─── 2. Reset ALL TCC permissions ───────────────────────────────
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Resetting TCC Permissions                           ${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo ""

# TCC services used by ShotPaste
TCC_SERVICES=(
  "ScreenCapture"
  "Microphone"
  "Accessibility"
  "PostEvent"
  "ListenEvent"
)

tcc_had_failure=false

for service in "${TCC_SERVICES[@]}"; do
  info "Resetting $service..."
  if tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null; then
    success "Reset $service for $BUNDLE_ID"
  else
    warn "Could not reset $service (app may not be installed or service not granted)"
    tcc_had_failure=true
  fi
done

info "Running catch-all TCC reset for $BUNDLE_ID..."
if tccutil reset All "$BUNDLE_ID" 2>/dev/null; then
  success "Reset all remaining TCC entries for $BUNDLE_ID"
else
  info "No additional TCC entries to reset"
fi

if $tcc_had_failure; then
  echo ""
  warn "Some TCC resets could not be completed automatically."
  info "If you face permission issues, you can manually remove"
  info "$APP_NAME from System Settings > Privacy & Security for the affected services."
fi

# ─── Done ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
print_box_line "  ✅ Permissions for $APP_NAME have been reset" "$GREEN"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
print_box_line "  Please relaunch the app to grant them again." "$GREEN"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}💡 Tip: You may need to log out and back in (or reboot)${NC}"
echo -e "${YELLOW}   for TCC changes to fully take effect.${NC}"
echo ""
