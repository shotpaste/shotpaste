#!/bin/bash
# Collect macOS crash and diagnostic reports for an app.
#
# APP_NAME is intentionally configurable so this can be reused across projects.

set -euo pipefail

APP_NAME="${APP_NAME:-ShotPaste}"
BUNDLE_ID="${BUNDLE_ID:-}"
DAYS="${DAYS:-14}"
OUTPUT_ROOT="${OUTPUT_ROOT:-build/crash-logs}"
INCLUDE_SYSTEM="${INCLUDE_SYSTEM:-1}"
INCLUDE_UNIFIED_LOG="${INCLUDE_UNIFIED_LOG:-1}"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; BLUE=$'\033[0;34m'; GREEN=$'\033[0;32m'
  RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; RESET=$'\033[0m'
else
  BOLD=""; BLUE=""; GREEN=""; RED=""; YELLOW=""; RESET=""
fi

status() { printf "%b%s:%b %s\n" "$1" "$2" "$RESET" "$3"; }
info() { status "${BLUE}${BOLD}" "info" "$*"; }
success() { status "${GREEN}${BOLD}" "success" "$*"; }
warn() { status "${YELLOW}${BOLD}" "warning" "$*" >&2; }
die() {
  status "${RED}${BOLD}" "error" "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Collects recent .crash, .ips, .hang, .spin, and .diag reports from macOS
DiagnosticReports folders. Also exports recent unified log error/fault messages
unless --skip-unified-log is used.

Options:
  --app NAME             App process name. Default: ${APP_NAME}
  --bundle-id ID         Bundle identifier to match inside reports.
  --days N               Search reports modified in last N days. Default: ${DAYS}
  --all                  Search all diagnostic reports. Unified log uses 30d.
  --output-dir DIR       Base output directory. Default: ${OUTPUT_ROOT}
  --skip-unified-log     Do not export unified log error/fault messages.
  --user-only            Search only ~/Library/Logs/DiagnosticReports.
  -h, --help             Show this help.

Examples:
  $0
  $0 --app ShotPaste --bundle-id com.ahtcfg24.shotpaste --days 7
  APP_NAME="My App" BUNDLE_ID=com.example.MyApp $0 --output-dir /tmp/crashes
EOF
}

value_for() {
  local option="$1"
  local value="${2:-}"
  [ -n "$value" ] || die "$option requires a value"
  printf "%s" "$value"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP_NAME="$(value_for "$1" "${2:-}")"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$(value_for "$1" "${2:-}")"; shift 2 ;;
    --days) DAYS="$(value_for "$1" "${2:-}")"; shift 2 ;;
    --all) DAYS="all"; shift ;;
    --output-dir) OUTPUT_ROOT="$(value_for "$1" "${2:-}")"; shift 2 ;;
    --skip-unified-log) INCLUDE_UNIFIED_LOG=0; shift ;;
    --user-only) INCLUDE_SYSTEM=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "This script requires macOS."
[ -n "$APP_NAME" ] || die "APP_NAME cannot be empty."

if [ "$DAYS" != "all" ]; then
  case "$DAYS" in ''|*[!0-9]*) die "--days must be a positive integer or --all." ;; esac
  [ "$DAYS" -gt 0 ] || die "--days must be greater than 0."
fi

for cmd in basename cp date find grep mkdir; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found."
done

SAFE_APP_NAME="${APP_NAME// /-}"
SAFE_APP_NAME="${SAFE_APP_NAME//\//-}"
OUT="${OUTPUT_ROOT%/}/${SAFE_APP_NAME}-$(date +%Y%m%d-%H%M%S)"
MATCH_COUNT=0
mkdir -p "$OUT"

write_manifest() {
  local host
  host="$(hostname 2>/dev/null || true)"
  {
    printf "app_name=%s\n" "$APP_NAME"
    printf "bundle_id=%s\n" "${BUNDLE_ID:-unset}"
    printf "days=%s\n" "$DAYS"
    printf "generated_at=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf "host=%s\n" "${host:-unknown}"
    command -v sw_vers >/dev/null 2>&1 && sw_vers
  } > "${OUT}/manifest.txt"
}

matches_report() {
  local report="$1"
  local base
  base="$(basename "$report")"

  case "$base" in *"$APP_NAME"*) return 0 ;; esac
  if [ -n "$BUNDLE_ID" ]; then
    case "$base" in *"$BUNDLE_ID"*) return 0 ;; esac
  fi

  grep -F -q "$APP_NAME" "$report" 2>/dev/null && return 0
  [ -n "$BUNDLE_ID" ] && grep -F -q "$BUNDLE_ID" "$report" 2>/dev/null
}

copy_report() {
  local report="$1"
  local label="$2"
  local base
  local target
  base="$(basename "$report")"
  target="${OUT}/${base}"
  [ ! -e "$target" ] || target="${OUT}/${label}-${base}"

  if cp -p "$report" "$target"; then
    MATCH_COUNT=$((MATCH_COUNT + 1))
    info "Copied ${report}"
  else
    warn "Could not copy ${report}"
  fi
}

scan_dir() {
  local dir="$1"
  local label="$2"
  [ -d "$dir" ] || { warn "Missing report directory: ${dir}"; return; }

  if [ "$DAYS" = "all" ]; then
    while IFS= read -r report; do
      matches_report "$report" && copy_report "$report" "$label"
    done < <(find "$dir" -maxdepth 1 -type f \( -name "*.crash" -o -name "*.ips" -o -name "*.hang" -o -name "*.spin" -o -name "*.diag" \) -print 2>/dev/null)
  else
    while IFS= read -r report; do
      matches_report "$report" && copy_report "$report" "$label"
    done < <(find "$dir" -maxdepth 1 -type f \( -name "*.crash" -o -name "*.ips" -o -name "*.hang" -o -name "*.spin" -o -name "*.diag" \) -mtime "-$DAYS" -print 2>/dev/null)
  fi

  return 0
}

write_unified_log() {
  [ "$INCLUDE_UNIFIED_LOG" = "1" ] || return 0
  command -v log >/dev/null 2>&1 || { warn "log not found; skip unified log."; return; }

  local last_arg="${DAYS}d"
  local safe_app="${APP_NAME//\"/}"
  local safe_bundle="${BUNDLE_ID//\"/}"
  local app_predicate="process == \"${safe_app}\""
  local predicate

  [ "$DAYS" = "all" ] && last_arg="30d"
  if [ -n "$safe_bundle" ]; then
    app_predicate="(${app_predicate} OR subsystem == \"${safe_bundle}\" OR eventMessage CONTAINS[c] \"${safe_bundle}\")"
  fi

  predicate="(${app_predicate}) AND (messageType == fault OR messageType == error OR eventMessage CONTAINS[c] \"crash\" OR eventMessage CONTAINS[c] \"termination\")"
  info "Exporting unified log errors/faults for last ${last_arg}"

  if log show --style compact --last "$last_arg" --predicate "$predicate" > "${OUT}/unified-log-errors.log" 2> "${OUT}/unified-log-errors.stderr"; then
    success "Unified log exported."
  else
    warn "Unified log export failed; see unified-log-errors.stderr."
  fi
}

write_manifest
info "Collecting crash reports for ${APP_NAME}"
info "Output: ${OUT}"

scan_dir "${HOME}/Library/Logs/DiagnosticReports" "user"
[ "$INCLUDE_SYSTEM" != "1" ] || scan_dir "/Library/Logs/DiagnosticReports" "system"
write_unified_log

[ "$MATCH_COUNT" -ne 0 ] || warn "No matching diagnostic reports found."
[ "$MATCH_COUNT" -eq 0 ] || success "Collected ${MATCH_COUNT} diagnostic report(s)."
success "Crash log bundle ready: ${OUT}"
