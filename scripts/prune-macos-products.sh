#!/usr/bin/env bash
# Remove stale generated ShotPaste app bundles while preserving canonical products.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INCLUDE_XCODE_DERIVED_DATA=0

if [[ "${1:-}" == "--include-xcode-derived-data" ]]; then
  INCLUDE_XCODE_DERIVED_DATA=1
elif [[ -n "${1:-}" ]]; then
  printf "Usage: %s [--include-xcode-derived-data]\n" "$0" >&2
  exit 1
fi

[[ "$(uname -s)" == "Darwin" ]] || {
  printf "error: This script only supports macOS.\n" >&2
  exit 1
}

CANONICAL_DEBUG="$ROOT_DIR/.build/macos/Debug/ShotPaste Debug.app"
CANONICAL_RELEASE="$ROOT_DIR/.build/macos/Release/ShotPaste.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
REMOVED=0

pgrep -x ShotPaste >/dev/null 2>&1 && pkill -x ShotPaste >/dev/null 2>&1 || true

remove_candidate() {
  local candidate="$1"
  local base_name
  base_name="$(basename "$candidate")"

  [[ "$candidate" != "$CANONICAL_DEBUG" && "$candidate" != "$CANONICAL_RELEASE" ]] || return 0
  [[ "$base_name" == "ShotPaste Debug.app" || "$base_name" == "ShotPaste.app" ]] || return 0

  case "$candidate" in
    "$ROOT_DIR/.build/"*|"$ROOT_DIR/build/"*|"$HOME/Library/Developer/Xcode/DerivedData/"*) ;;
    *)
      printf "error: Refusing to remove app outside scoped build roots: %s\n" "$candidate" >&2
      exit 1
      ;;
  esac

  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$candidate" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- "$candidate"
  printf "removed: %s\n" "$candidate"
  REMOVED=$((REMOVED + 1))
}

scan_root() {
  local search_root="$1"
  [[ -d "$search_root" ]] || return 0
  while IFS= read -r -d '' candidate; do
    remove_candidate "$candidate"
  done < <(
    /usr/bin/find "$search_root" -type d \( \
      -name 'ShotPaste Debug.app' -o -name 'ShotPaste.app' \
    \) -prune -print0
  )
}

scan_root "$ROOT_DIR/.build"
scan_root "$ROOT_DIR/build"
if [[ "$INCLUDE_XCODE_DERIVED_DATA" -eq 1 ]]; then
  scan_root "$HOME/Library/Developer/Xcode/DerivedData"
fi

printf "info: Removed %d stale generated app bundle(s).\n" "$REMOVED"
