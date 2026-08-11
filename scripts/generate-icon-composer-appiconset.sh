#!/usr/bin/env bash
set -euo pipefail

ICON_DOCUMENT=""
SOURCE_PNG=""
APPICONSET_DIR=""
FILENAME_PREFIX=""
PLATFORM="macOS"
RENDITION="Default"
CANVAS_SIZE=1024
ARTWORK_SIZE=832
KEEP_WORK_DIR=0

usage() {
  cat <<'USAGE'
Generate a padded macOS AppIcon.appiconset from an Apple Icon Composer .icon file.

Usage:
  generate-icon-composer-appiconset.sh path/to/AppIcon.icon [options]
  generate-icon-composer-appiconset.sh --source-png path/to/IconComposerExport.png [options]

Options:
  --icon-document PATH   Icon Composer .icon package to render.
  --source-png PATH      Use an already-exported Icon Composer PNG instead.
  --appiconset PATH      Output AppIcon.appiconset directory.
                         Default: AppIcon.appiconset next to the input file.
  --filename-prefix NAME Prefix for generated PNG names. Default: input basename.
  --platform NAME        ictool platform. Default: macOS.
  --rendition NAME       ictool rendition. Default: Default.
  --canvas-size PX       Final master canvas size. Default: 1024.
  --artwork-size PX      Rendered icon bounding box. Default: 832.
  --keep-work-dir        Keep temporary render files for inspection.
  -h, --help             Show this help.

Examples:
  ./generate-icon-composer-appiconset.sh MyIcon.icon
  ./generate-icon-composer-appiconset.sh MyIcon.icon --appiconset MyApp/Assets.xcassets/AppIcon.appiconset
  ./generate-icon-composer-appiconset.sh --source-png IconComposerExport.png --filename-prefix MyIcon

Dependencies:
  - macOS + Xcode's Icon Composer ictool, unless --source-png is used.
  - ImageMagick's magick command.
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

require_positive_int() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer, got '$value'"
}

sanitize_prefix() {
  local value="$1"
  value="${value%/}"
  value="${value##*/}"
  value="${value%.icon}"
  value="${value%.*}"
  value="${value// /-}"
  value="${value//[^A-Za-z0-9_.-]/-}"
  printf '%s\n' "${value:-AppIcon}"
}

find_ictool() {
  local candidate developer_dir
  if [[ -n "${ICTOOL:-}" && -x "${ICTOOL:-}" ]]; then
    printf '%s\n' "$ICTOOL"
    return 0
  fi

  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -n "$developer_dir" ]]; then
    candidate="${developer_dir%/Contents/Developer}/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  fi

  candidate="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
  [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --icon-document) ICON_DOCUMENT="${2:?Missing path for --icon-document}"; shift 2 ;;
    --source-png) SOURCE_PNG="${2:?Missing path for --source-png}"; shift 2 ;;
    --appiconset) APPICONSET_DIR="${2:?Missing path for --appiconset}"; shift 2 ;;
    --filename-prefix) FILENAME_PREFIX="${2:?Missing value for --filename-prefix}"; shift 2 ;;
    --platform) PLATFORM="${2:?Missing value for --platform}"; shift 2 ;;
    --rendition) RENDITION="${2:?Missing value for --rendition}"; shift 2 ;;
    --canvas-size) CANVAS_SIZE="${2:?Missing value for --canvas-size}"; shift 2 ;;
    --artwork-size) ARTWORK_SIZE="${2:?Missing value for --artwork-size}"; shift 2 ;;
    --keep-work-dir) KEEP_WORK_DIR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) die "Unknown option: $1" ;;
    *)
      if [[ -z "$ICON_DOCUMENT" && -z "$SOURCE_PNG" ]]; then
        INPUT_ARG="${1%/}"
        if [[ -d "$INPUT_ARG" && "$INPUT_ARG" == *.icon ]]; then ICON_DOCUMENT="$INPUT_ARG"; else SOURCE_PNG="$1"; fi
        shift
      else
        die "Unexpected positional argument: $1"
      fi
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "this script requires macOS"
[[ -z "$ICON_DOCUMENT" || -z "$SOURCE_PNG" ]] || die "use either --icon-document or --source-png, not both"
[[ -n "$ICON_DOCUMENT$SOURCE_PNG" ]] || { usage >&2; exit 2; }

require_positive_int "--canvas-size" "$CANVAS_SIZE"
require_positive_int "--artwork-size" "$ARTWORK_SIZE"
(( ARTWORK_SIZE < CANVAS_SIZE )) || die "--artwork-size must be smaller than --canvas-size"
(( (CANVAS_SIZE - ARTWORK_SIZE) % 2 == 0 )) || die "canvas/artwork difference must be even for centered padding"

MAGICK="$(command -v magick || true)"
[[ -n "$MAGICK" ]] || die "ImageMagick is required. Install with: brew install imagemagick"

INPUT_PATH="${ICON_DOCUMENT:-$SOURCE_PNG}"
[[ -n "$APPICONSET_DIR" ]] || APPICONSET_DIR="$(cd "$(dirname "$INPUT_PATH")" && pwd)/AppIcon.appiconset"
[[ -n "$FILENAME_PREFIX" ]] || FILENAME_PREFIX="$(sanitize_prefix "$INPUT_PATH")"

WORK_DIR="$(mktemp -d)"
cleanup() { [[ "$KEEP_WORK_DIR" -eq 1 ]] && echo "Kept work dir: $WORK_DIR" || rm -rf "$WORK_DIR"; }
trap cleanup EXIT

RAW_ICON="$WORK_DIR/icon-composer-raw.png"
PADDED_MASTER="$WORK_DIR/icon-padded-${CANVAS_SIZE}.png"

if [[ -n "$SOURCE_PNG" ]]; then
  [[ -f "$SOURCE_PNG" ]] || die "source PNG not found: $SOURCE_PNG"
  cp "$SOURCE_PNG" "$RAW_ICON"
  echo "Using source PNG: $SOURCE_PNG"
else
  [[ -d "$ICON_DOCUMENT" ]] || die "Icon Composer document not found: $ICON_DOCUMENT"
  ICTOOL_BIN="$(find_ictool)" || die "ictool not found. Install/use Xcode with Icon Composer, or pass --source-png."
  "$ICTOOL_BIN" "$ICON_DOCUMENT" \
    --export-image \
    --output-file "$RAW_ICON" \
    --platform "$PLATFORM" \
    --rendition "$RENDITION" \
    --width "$CANVAS_SIZE" \
    --height "$CANVAS_SIZE" \
    --scale 1 \
    >/dev/null
  echo "Rendered Icon Composer document: $ICON_DOCUMENT"
fi

read -r RAW_WIDTH RAW_HEIGHT < <("$MAGICK" identify -format '%w %h\n' "$RAW_ICON")
[[ "$RAW_WIDTH" == "$RAW_HEIGHT" ]] || die "source image must be square, got ${RAW_WIDTH}x${RAW_HEIGHT}"

RAW_TRIM="$("$MAGICK" "$RAW_ICON" -alpha extract -format '%@' info:)"
if [[ "$RAW_TRIM" != "${RAW_WIDTH}x${RAW_HEIGHT}+0+0" ]]; then
  echo "warning: source already has transparency bounds: $RAW_TRIM" >&2
  echo "warning: continuing; avoid passing an already-padded AppIcon output." >&2
fi

"$MAGICK" "$RAW_ICON" \
  -resize "${ARTWORK_SIZE}x${ARTWORK_SIZE}" \
  -background none \
  -gravity center \
  -extent "${CANVAS_SIZE}x${CANVAS_SIZE}" \
  "$PADDED_MASTER"

mkdir -p "$APPICONSET_DIR"
rm -f "$APPICONSET_DIR"/*.png

ICON_SPECS=("16 1" "16 2" "32 1" "32 2" "128 1" "128 2" "256 1" "256 2" "512 1" "512 2")
CONTENTS_JSON="$APPICONSET_DIR/Contents.json"
{
  printf '{\n  "images" : [\n'
  for index in "${!ICON_SPECS[@]}"; do
    read -r POINTS SCALE <<<"${ICON_SPECS[$index]}"
    PIXELS=$((POINTS * SCALE))
    ARTWORK_PIXELS=$((PIXELS * ARTWORK_SIZE / CANVAS_SIZE))
    FILENAME="${FILENAME_PREFIX}-macOS-${POINTS}x${POINTS}@${SCALE}x.png"
    OUTPUT_FILE="$APPICONSET_DIR/$FILENAME"

    if [[ "$PIXELS" -eq "$CANVAS_SIZE" ]]; then
      cp "$PADDED_MASTER" "$OUTPUT_FILE"
    else
      "$MAGICK" "$RAW_ICON" -filter Lanczos -resize "${ARTWORK_PIXELS}x${ARTWORK_PIXELS}" \
        -background none -gravity center -extent "${PIXELS}x${PIXELS}" "$OUTPUT_FILE"
    fi

    printf '    {\n      "filename" : "%s",\n      "idiom" : "mac",\n      "scale" : "%sx",\n      "size" : "%sx%s"\n    }' "$FILENAME" "$SCALE" "$POINTS" "$POINTS"
    [[ "$index" -lt $((${#ICON_SPECS[@]} - 1)) ]] && printf ','
    printf '\n'
  done
  printf '  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
} > "$CONTENTS_JSON"

EXPECTED_TRIM="${ARTWORK_SIZE}x${ARTWORK_SIZE}+$(((CANVAS_SIZE - ARTWORK_SIZE) / 2))+$(((CANVAS_SIZE - ARTWORK_SIZE) / 2))"
MASTER_FILE="$APPICONSET_DIR/${FILENAME_PREFIX}-macOS-512x512@2x.png"
ACTUAL_TRIM="$("$MAGICK" "$MASTER_FILE" -alpha extract -format '%@' info:)"
[[ "$ACTUAL_TRIM" == "$EXPECTED_TRIM" ]] || die "unexpected ${CANVAS_SIZE}px alpha bounds: expected $EXPECTED_TRIM, got $ACTUAL_TRIM"

echo "Generated padded AppIcon assets: $APPICONSET_DIR"
echo "${CANVAS_SIZE}px alpha bounds: $ACTUAL_TRIM"
