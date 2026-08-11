#!/usr/bin/env bash
set -euo pipefail

# Get the script directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$DIR/.."

cd "$ROOT_DIR"

if command -v swiftformat >/dev/null 2>&1; then
  echo "Formatting codebase..."
  swiftformat platforms/mac/LiteScreen platforms/mac/LiteScreenTests platforms/mac/Tools
else
  echo "error: SwiftFormat is not installed. Run 'brew install swiftformat' first."
  exit 1
fi
