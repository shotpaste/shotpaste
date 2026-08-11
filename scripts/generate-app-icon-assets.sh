#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$ROOT_DIR/scripts/generate-icon-composer-appiconset.sh"

HAS_INPUT=0
HAS_APPICONSET=0
HAS_PREFIX=0
EXPECTS_VALUE=""

for arg in "$@"; do
  if [[ -n "$EXPECTS_VALUE" ]]; then
    EXPECTS_VALUE=""
    continue
  fi

  case "$arg" in
    --icon-document|--source-png)
      HAS_INPUT=1
      EXPECTS_VALUE="$arg"
      ;;
    --appiconset)
      HAS_APPICONSET=1
      EXPECTS_VALUE="$arg"
      ;;
    --filename-prefix)
      HAS_PREFIX=1
      EXPECTS_VALUE="$arg"
      ;;
    --canvas-size|--artwork-size|--platform|--rendition)
      EXPECTS_VALUE="$arg"
      ;;
    --*)
      ;;
    *)
      HAS_INPUT=1
      ;;
  esac
done

DEFAULT_ARGS=()
[[ "$HAS_INPUT" -eq 1 ]] || DEFAULT_ARGS+=(--source-png "$ROOT_DIR/assets/lite-screen-icon.png")
[[ "$HAS_APPICONSET" -eq 1 ]] || DEFAULT_ARGS+=(--appiconset "$ROOT_DIR/platforms/mac/LiteScreen/Resources/Assets.xcassets/AppIcon.appiconset")
[[ "$HAS_PREFIX" -eq 1 ]] || DEFAULT_ARGS+=(--filename-prefix "LiteScreenIcon")

exec "$GENERATOR" "${DEFAULT_ARGS[@]}" "$@"
