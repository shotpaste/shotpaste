#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ShotPaste"
RELEASE_BUNDLE_NAME="ShotPaste"
DEBUG_BUNDLE_NAME="ShotPaste Debug"
SCHEME="ShotPaste"
PROJECT="platforms/mac/ShotPaste.xcodeproj"
LOG_SUBSYSTEM="${LOG_SUBSYSTEM:-ShotPaste}"

MODE="run"
CONFIGURATION="${CONFIGURATION:-Debug}"
LOG_LEVEL="${LOG_LEVEL:-default,error,fault}"
CLEAN=0
QUIET=1
MARKETING_VERSION_OVERRIDE="${SHOTPASTE_MARKETING_VERSION:-}"
BUILD_NUMBER_OVERRIDE="${SHOTPASTE_BUILD_NUMBER:-}"
RELEASE_ARM64_ONLY="${SHOTPASTE_RELEASE_ARM64_ONLY:-0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS_ROOT="$ROOT_DIR/.build/macos"
DERIVED_DATA_PATH="$PRODUCTS_ROOT/DerivedData"

if [[ -t 1 ]]; then
  BLUE=$'\033[0;34m'
  GREEN=$'\033[0;32m'
  RED=$'\033[0;31m'
  BOLD=$'\033[1m'
  NC=$'\033[0m'
else
  BLUE=""
  GREEN=""
  RED=""
  BOLD=""
  NC=""
fi

info() { printf "%sinfo:%s %s\n" "$BLUE$BOLD" "$NC" "$1"; }
success() { printf "%ssuccess:%s %s\n" "$GREEN$BOLD" "$NC" "$1"; }
fail() {
  printf "%serror:%s %s\n" "$RED$BOLD" "$NC" "$1" >&2
  exit 1
}

usage() {
  cat <<USAGE
${BOLD}Usage:${NC} $0 [build|run|--logs|--telemetry|--debug|--verify] [options]

${BOLD}Modes:${NC}
  build               Build and sign the canonical app without launching it
  run                 Kill, build, and launch ShotPaste (default)
  --logs, logs        Launch then stream unified logs for process == "ShotPaste"
  --telemetry         Launch then stream unified logs for subsystem == "$LOG_SUBSYSTEM"
  --debug, debug      Build then launch the app binary under lldb
  --verify, verify    Launch and confirm the ShotPaste process is running

${BOLD}Options:${NC}
  --configuration C   Build configuration: Debug or Release. Default: Debug
  --log-level LEVELS  default,info,debug,error,fault,all. Default: default,error,fault
  --clean             Clean before building
  --verbose           Show full xcodebuild output
  --help, -h          Show this help

${BOLD}CI release environment:${NC}
  SHOTPASTE_MARKETING_VERSION  Override MARKETING_VERSION with stable SemVer
  SHOTPASTE_BUILD_NUMBER       Override CURRENT_PROJECT_VERSION with an integer
  SHOTPASTE_RELEASE_ARM64_ONLY Build an arm64-only Release app when set to 1

${BOLD}Examples:${NC}
  $0
  $0 build
  $0 --verify
  $0 --logs --log-level all
  $0 --configuration Release
USAGE
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "This script only supports macOS."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      build|--build-only)
        MODE="build"
        shift
        ;;
      run)
        MODE="run"
        shift
        ;;
      --logs|logs)
        MODE="logs"
        shift
        ;;
      --telemetry|telemetry)
        MODE="telemetry"
        shift
        ;;
      --debug|debug)
        MODE="debug"
        shift
        ;;
      --verify|verify)
        MODE="verify"
        shift
        ;;
      --configuration)
        [[ $# -ge 2 ]] || fail "--configuration requires a value."
        CONFIGURATION="$2"
        shift 2
        ;;
      --derived-data|--derived-data-path)
        fail "Custom DerivedData paths are disabled; reuse .build/macos/DerivedData."
        ;;
      --log-level)
        [[ $# -ge 2 ]] || fail "--log-level requires a value."
        LOG_LEVEL="$2"
        shift 2
        ;;
      --clean)
        CLEAN=1
        shift
        ;;
      --verbose)
        QUIET=0
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

validate_configuration() {
  case "$CONFIGURATION" in
    Debug|Release) ;;
    *) fail "Unsupported configuration '$CONFIGURATION'; use Debug or Release." ;;
  esac
}

validate_build_overrides() {
  if [[ -n "$MARKETING_VERSION_OVERRIDE" && ! "$MARKETING_VERSION_OVERRIDE" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "SHOTPASTE_MARKETING_VERSION must be stable SemVer, for example 1.2.3."
  fi

  if [[ -n "$BUILD_NUMBER_OVERRIDE" && ! "$BUILD_NUMBER_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
    fail "SHOTPASTE_BUILD_NUMBER must be a positive integer."
  fi

  case "$RELEASE_ARM64_ONLY" in
    0) ;;
    1)
      [[ "$CONFIGURATION" == "Release" ]] || fail \
        "SHOTPASTE_RELEASE_ARM64_ONLY=1 requires the Release configuration."
      ;;
    *) fail "SHOTPASTE_RELEASE_ARM64_ONLY must be 0 or 1." ;;
  esac
}

message_type_predicate() {
  local levels="$1"
  local type_clauses=""

  if [[ "$levels" == "all" ]]; then
    printf ""
    return
  fi

  IFS=',' read -r -a level_array <<<"$levels"
  for level in "${level_array[@]}"; do
    level="${level//[[:space:]]/}"
    case "$level" in
      default|info|debug|error|fault)
        if [[ -n "$type_clauses" ]]; then
          type_clauses="$type_clauses OR messageType == $level"
        else
          type_clauses="messageType == $level"
        fi
        ;;
      *)
        fail "Invalid log level: '$level'. Use default, info, debug, error, fault, or all."
        ;;
    esac
  done

  printf " AND (%s)" "$type_clauses"
}

process_log_predicate() {
  printf "process == \"%s\"" "$APP_NAME"
  message_type_predicate "$LOG_LEVEL"
}

telemetry_log_predicate() {
  printf "subsystem == \"%s\"" "$LOG_SUBSYSTEM"
  message_type_predicate "$LOG_LEVEL"
}

build_products_dir() {
  printf "%s/%s" "$PRODUCTS_ROOT" "$CONFIGURATION"
}

app_bundle_path() {
  local bundle_name="$RELEASE_BUNDLE_NAME"
  if [[ "$CONFIGURATION" == "Debug" ]]; then
    bundle_name="$DEBUG_BUNDLE_NAME"
  fi

  printf "%s/%s.app" "$(build_products_dir)" "$bundle_name"
}

app_binary_path() {
  printf "%s/Contents/MacOS/%s" "$(app_bundle_path)" "$APP_NAME"
}

stop_app() {
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    info "Stopping existing $APP_NAME process..."
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 0.5
  fi
}

run_xcodebuild() {
  local action="$1"
  local args=(
    xcodebuild
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
    "CONFIGURATION_BUILD_DIR=$PRODUCTS_ROOT/$CONFIGURATION"
    COMPILER_INDEX_STORE_ENABLE=NO
    INDEX_ENABLE_DATA_STORE=NO
    CODE_SIGN_IDENTITY=
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
    SHOTPASTE_SKIP_POST_SIGN=1
  )

  if [[ "$QUIET" -eq 1 ]]; then
    args+=(-quiet)
  fi

  if [[ -n "$MARKETING_VERSION_OVERRIDE" ]]; then
    args+=("MARKETING_VERSION=$MARKETING_VERSION_OVERRIDE")
  fi
  if [[ -n "$BUILD_NUMBER_OVERRIDE" ]]; then
    args+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER_OVERRIDE")
  fi
  if [[ "$RELEASE_ARM64_ONLY" == "1" ]]; then
    args+=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_COMPILATION_MODE=incremental)
  fi

  # Xcode 26.6 / Swift 6.3.3 can crash in EarlyPerfInliner while compiling this
  # Swift 5 target. The local packaging dry run enables this narrow workaround;
  # the pinned GitHub release toolchain remains optimized.
  if [[ "$CONFIGURATION" == "Release" && "${SHOTPASTE_LOCAL_RELEASE_COMPILER_WORKAROUND:-0}" == "1" ]]; then
    args+=(SWIFT_COMPILATION_MODE=incremental SWIFT_OPTIMIZATION_LEVEL=-Onone)
  fi

  args+=("$action")
  "${args[@]}"
}

build_app() {
  cd "$ROOT_DIR"

  local app_bundle
  app_bundle="$(app_bundle_path)"

  if [[ "$CLEAN" -eq 1 ]]; then
    info "Cleaning $SCHEME ($CONFIGURATION)..."
    run_xcodebuild clean
  fi

  if [[ -d "$app_bundle" ]]; then
    info "Removing previous canonical app bundle before rebuilding..."
    /bin/rm -rf -- "$app_bundle"
  fi

  info "Building $SCHEME ($CONFIGURATION)..."
  run_xcodebuild build

  [[ -d "$app_bundle" ]] || fail "Build finished but app bundle was not found: $app_bundle"
  [[ -x "$(app_binary_path)" ]] || fail "Built app binary is not executable: $(app_binary_path)"

  "$ROOT_DIR/scripts/sign-macos-app.sh" "$app_bundle" "$CONFIGURATION"
  "$ROOT_DIR/scripts/prune-macos-products.sh"

  success "Canonical signed build ready: $app_bundle"
}

open_app() {
  local app_bundle
  app_bundle="$(app_bundle_path)"
  info "Launching $APP_NAME..."
  /usr/bin/open -n "$app_bundle"
  success "Launched $APP_NAME"
}

verify_app() {
  open_app
  sleep 2

  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    success "$APP_NAME is running."
  else
    fail "$APP_NAME did not stay running after launch."
  fi
}

stream_logs() {
  local predicate="$1"

  open_app

  cleanup_stream() {
    printf "\n"
    info "Stopping $APP_NAME..."
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    success "App stopped."
  }
  trap cleanup_stream INT TERM

  info "Streaming logs for predicate: $predicate"
  /usr/bin/log stream --info --debug --style compact --predicate "$predicate"
}

launch_debugger() {
  require_command lldb
  info "Launching under lldb..."
  exec lldb -o run -- "$(app_binary_path)"
}

main() {
  parse_args "$@"
  validate_configuration
  validate_build_overrides
  require_macos
  require_command xcodebuild
  require_command codesign
  require_command security
  require_command pgrep
  require_command pkill

  case "$CONFIGURATION" in
    Debug|Release) ;;
    *) fail "Configuration must be Debug or Release." ;;
  esac

  cd "$ROOT_DIR"
  stop_app
  build_app

  case "$MODE" in
    build)
      ;;
    run)
      open_app
      ;;
    logs)
      stream_logs "$(process_log_predicate)"
      ;;
    telemetry)
      stream_logs "$(telemetry_log_predicate)"
      ;;
    verify)
      verify_app
      ;;
    debug)
      launch_debugger
      ;;
    *)
      fail "Unsupported mode: $MODE"
      ;;
  esac
}

main "$@"
