#!/bin/bash
# Compile and run the reproducible OCR README benchmark.
#
# Usage:
#   ./scripts/run-ocr-readme-benchmark.sh

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "::error::This benchmark requires macOS." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "::error::swiftc not found. Install Xcode Command Line Tools first." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
BINARY_PATH="${TMP_ROOT%/}/shotpaste-ocr-readme-benchmark"
MODULE_CACHE_PATH="${TMP_ROOT%/}/shotpaste-ocr-readme-benchmark-module-cache"
STDERR_PATH="${TMP_ROOT%/}/shotpaste-ocr-readme-benchmark.stderr"

cd "$REPO_ROOT"

swiftc -module-cache-path "$MODULE_CACHE_PATH" \
  -o "$BINARY_PATH" \
  platforms/mac/Tools/Benchmarks/ocr/ocr-readme-benchmark.swift \
  platforms/mac/ShotPaste/Services/Media/OCRService.swift \
  platforms/mac/ShotPaste/Services/Media/OCR/VerticalCJKTextNormalizer.swift \
  platforms/mac/ShotPaste/Services/Media/OCR/VerticalCJKBitmapAnalysis.swift \
  platforms/mac/ShotPaste/Services/Media/OCR/OCRRequest.swift \
  platforms/mac/ShotPaste/Services/Media/OCR/OCRResult.swift \
  platforms/mac/ShotPaste/Services/Media/OCR/VisionOCRProfile.swift \
  platforms/mac/ShotPaste/Services/Media/OCR/OCRBenchmarkMetrics.swift \
  platforms/mac/ShotPaste/Services/Media/OCR/OCRBenchmarkHarness.swift

: > "$STDERR_PATH"
set +e
"$BINARY_PATH" "$@" 2> "$STDERR_PATH"
STATUS=$?
set -e

grep -v '^sysctlbyname for kern.hv_vmm_present failed with status -1$' "$STDERR_PATH" >&2 || true
exit "$STATUS"
