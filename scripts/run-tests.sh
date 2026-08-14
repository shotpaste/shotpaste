#!/bin/bash
# Run the ShotPaste XCTest suite with CI-like local settings.
#
# Usage:
#   ./scripts/run-tests.sh
#   ./scripts/run-tests.sh -only-testing:ShotPasteTests/SomeTests
#   ./scripts/run-tests.sh --open-result

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/scripts/macos-app-variant.sh"
cd "$ROOT_DIR"

PROJECT="${PROJECT:-platforms/mac/ShotPaste.xcodeproj}"
SCHEME="${SCHEME:-ShotPaste}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
PRODUCTS_ROOT="$BUILD_DIR/TestProducts"
# If running in CI, default to local package cache to avoid caching issues on CI runners.
# Otherwise, default to empty to let xcodebuild use the user's global SwiftPM cache for speed.
if [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
  SOURCE_PACKAGES_PATH="$BUILD_DIR/SourcePackages"
else
  SOURCE_PACKAGES_PATH=""
fi
MODULE_CACHE_PATH="$BUILD_DIR/swift-module-cache"
RESULT_BUNDLE_PATH="$BUILD_DIR/ci-test.xcresult"
LOG_PATH="$BUILD_DIR/ci-test.log"
OPEN_RESULT=0
XCODEBUILD_ARGS=()

if [ -t 1 ]; then
  BOLD=$'\033[1m'
  BLUE=$'\033[0;34m'
  GREEN=$'\033[0;32m'
  RED=$'\033[0;31m'
  YELLOW=$'\033[0;33m'
  RESET=$'\033[0m'
else
  BOLD=""
  BLUE=""
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
fi

info() { printf "%binfo:%b %s\n" "${BLUE}${BOLD}" "$RESET" "$*"; }
success() { printf "%bsuccess:%b %s\n" "${GREEN}${BOLD}" "$RESET" "$*"; }
warn() { printf "%bwarning:%b %s\n" "${YELLOW}${BOLD}" "$RESET" "$*" >&2; }
error() { printf "%berror:%b %s\n" "${RED}${BOLD}" "$RESET" "$*" >&2; }
die() {
  error "$*"
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [XCODEBUILD_TEST_OPTIONS]

Runs xcodebuild test with local build artifacts under ./build.
DerivedData, the module cache, the log, and the result bundle always reuse their
canonical paths so repeated test runs do not create parallel copies.

Options:
  --configuration NAME   Xcode configuration: Debug or Release. Default: ${CONFIGURATION}
  --destination VALUE    Xcode destination. Default: ${DESTINATION}
  --open-result          Open the .xcresult bundle when done.
  -h, --help             Show this help.

Examples:
  $0
  $0 -only-testing:ShotPasteTests/CaptureOutputNamingTests
  SHOTPASTE_RUN_MICROPHONE_INTEGRATION=1 $0 -only-testing:ShotPasteTests/MicrophoneAudioCapturerTests/testMicrophoneAudioCapturerStartStopRealMicrophoneIntegration
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "$1 not found. Install Xcode Command Line Tools first."
  fi
}

take_value() {
  local option="$1"
  local value="${2:-}"
  if [ -z "$value" ]; then
    die "$option requires a value"
  fi
  printf "%s" "$value"
}

append_xcodebuild_arg() {
  local argument="$1"
  case "$argument" in
    -configuration|-configuration=*)
      die "$argument is disabled; use --configuration Debug or --configuration Release."
      ;;
    -derivedDataPath|-derivedDataPath=*|-resultBundlePath|-resultBundlePath=*|-clonedSourcePackagesDirPath|-clonedSourcePackagesDirPath=*)
      die "$argument is disabled; local tests must reuse the canonical paths under ./build."
      ;;
    BUILD_DIR=*|CONFIGURATION_BUILD_DIR=*|OBJROOT=*|SYMROOT=*|DSTROOT=*|SHARED_PRECOMPS_DIR=*|MODULE_CACHE_DIR=*|CLANG_MODULE_CACHE_PATH=*)
      die "$argument is disabled; local tests must reuse the canonical paths under ./build."
      ;;
  esac
  XCODEBUILD_ARGS+=("$argument")
}

validate_configuration() {
  case "$CONFIGURATION" in
    Debug|Release) ;;
    *) die "Unsupported configuration '$CONFIGURATION'; use Debug or Release." ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --configuration)
      CONFIGURATION="$(take_value "$1" "${2:-}")"
      shift 2
      ;;
    --destination)
      DESTINATION="$(take_value "$1" "${2:-}")"
      shift 2
      ;;
    --open-result)
      OPEN_RESULT=1
      shift
      ;;
    --derived-data|--log|--result-bundle|--source-packages|--keep-result)
      die "$1 is disabled; local tests must reuse the canonical paths under ./build."
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        append_xcodebuild_arg "$1"
        shift
      done
      ;;
    *)
      append_xcodebuild_arg "$1"
      shift
      ;;
  esac
done

validate_configuration
macos_app_variant_validate_configuration "$CONFIGURATION"

if [ "$(uname -s)" != "Darwin" ]; then
  die "This script requires macOS."
fi

require_command xcodebuild
require_command grep
require_command tail

mkdir_paths=("$BUILD_DIR" "$DERIVED_DATA_PATH" "$MODULE_CACHE_PATH")
mkdir_paths+=("$PRODUCTS_ROOT")
if [[ -n "$SOURCE_PACKAGES_PATH" ]]; then
  mkdir_paths+=("$SOURCE_PACKAGES_PATH")
fi
mkdir -p "${mkdir_paths[@]}"

cleanup_test_apps() {
  # XCTest needs an app host while running, but it must not become another
  # launchable ShotPaste copy after the test process exits.
  rm -rf \
    "$PRODUCTS_ROOT/Debug/$(macos_app_variant_setting Debug SHOTPASTE_DISPLAY_NAME).app" \
    "$PRODUCTS_ROOT/Release/$(macos_app_variant_setting Release SHOTPASTE_DISPLAY_NAME).app"
}
trap cleanup_test_apps EXIT

rm -rf "$RESULT_BUNDLE_PATH"

info "Running ${SCHEME} tests"
info "Log: ${LOG_PATH}"
info "Result bundle: ${RESULT_BUNDLE_PATH}"

set +e
set +u
XCODEBUILD_CMD=(
  xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -resultBundlePath "$RESULT_BUNDLE_PATH"
  "CONFIGURATION_BUILD_DIR=$PRODUCTS_ROOT/$CONFIGURATION"
  COMPILER_INDEX_STORE_ENABLE=NO
  INDEX_ENABLE_DATA_STORE=NO
  # Release normally hides internal declarations from @testable imports. This
  # override applies only to the test invocation; canonical Release builds keep
  # their normal production setting.
  ENABLE_TESTABILITY=YES
  # Test hosts are disposable and removed on exit. Keeping them unsigned avoids
  # Hardened Runtime library-validation failures between separately ad-hoc-signed
  # host and XCTest bundles; canonical runnable apps are signed by the build script.
  CODE_SIGN_IDENTITY=
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  SHOTPASTE_SKIP_POST_SIGN=1
)

if [[ -n "$SOURCE_PACKAGES_PATH" ]]; then
  XCODEBUILD_CMD+=(-clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH")
fi

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH" "${XCODEBUILD_CMD[@]}" "${XCODEBUILD_ARGS[@]}" test > "$LOG_PATH" 2>&1
STATUS=$?
set -u
set -e

if [ "$STATUS" -ne 0 ]; then
  error "Tests failed with status ${STATUS}."
  if [ -f "$LOG_PATH" ]; then
    warn "Likely failures:"
    grep -E "Test case '.*' failed|Failing tests:|\\*\\* TEST FAILED \\*\\*|error:" "$LOG_PATH" || true
    warn "Last 200 log lines:"
    tail -200 "$LOG_PATH"
  fi
  exit "$STATUS"
fi

if [ -f "$LOG_PATH" ]; then
  tail -20 "$LOG_PATH"
fi

success "Tests passed."

if [ "$OPEN_RESULT" -eq 1 ]; then
  open "$RESULT_BUNDLE_PATH"
fi
