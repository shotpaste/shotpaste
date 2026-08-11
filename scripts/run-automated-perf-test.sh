#!/bin/bash
# Automated end-to-end performance & leak profiling for Lite Screen
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROCESS_NAME="LiteScreen"
APP_BUNDLE="$ROOT_DIR/.build/macos/Debug/Lite Screen Debug.app"

cd "$ROOT_DIR"

echo "=========================================================="
echo "⚡ AUTOMATED LITE SCREEN PERFORMANCE & MEMORY LEAK BENCHMARK"
echo "=========================================================="

PID=$(pgrep -x "$PROCESS_NAME" | head -n 1 || true)
if [ -z "$PID" ]; then
    echo "Building and launching the canonical Lite Screen Debug app..."
    "$ROOT_DIR/scripts/build_and_run.sh" build
    open -n "$APP_BUNDLE"
    sleep 3
    PID=$(pgrep -x "$PROCESS_NAME" | head -n 1 || true)
fi

if [ -z "$PID" ]; then
    echo "❌ Error: Unable to locate or launch Lite Screen process."
    exit 1
fi

echo "Connected to Lite Screen (PID: $PID)"

measure() {
    local label="$1"
    local duration="$2"
    local end_time=$(($(date +%s) + duration))
    local max_ram=0
    local min_ram=99999
    local max_cpu=0
    local min_cpu=99999
    local count=0
    local total_ram=0
    local total_cpu=0

    while [ $(date +%s) -lt $end_time ]; do
        STATS=$(ps -p "$PID" -o %cpu=,rss= 2>/dev/null || true)
        if [ -n "$STATS" ]; then
            CPU=$(echo "$STATS" | awk '{print $1}')
            RSS_KB=$(echo "$STATS" | awk '{print $2}')
            RAM_MB=$(echo "scale=2; $RSS_KB / 1024" | bc)

            count=$((count+1))
            total_ram=$(echo "$total_ram + $RAM_MB" | bc)
            total_cpu=$(echo "$total_cpu + $CPU" | bc)

            if (( $(echo "$RAM_MB > $max_ram" | bc -l) )); then max_ram=$RAM_MB; fi
            if (( $(echo "$RAM_MB < $min_ram" | bc -l) )); then min_ram=$RAM_MB; fi
            if (( $(echo "$CPU > $max_cpu" | bc -l) )); then max_cpu=$CPU; fi
            if (( $(echo "$CPU < $min_cpu" | bc -l) )); then min_cpu=$CPU; fi
        fi
        sleep 1
    done

    if [ $count -gt 0 ]; then
        local avg_ram=$(echo "scale=2; $total_ram / $count" | bc)
        local avg_cpu=$(echo "scale=2; $total_cpu / $count" | bc)
        printf "| %-22s | %8.2f MB | %8.2f MB | %8.2f MB | %6.1f%% | %6.1f%% |\n" "$label" "$min_ram" "$max_ram" "$avg_ram" "$max_cpu" "$avg_cpu"
    fi
}

printf "\n| %-22s | %11s | %11s | %11s | %7s | %7s |\n" "Phase" "Min RAM" "Peak RAM" "Avg RAM" "Peak CPU" "Avg CPU"
printf "|------------------------|-------------|-------------|-------------|---------|---------|\n"

# Phase 1: Baseline Idle
measure "1. Idle Baseline" 5

# Phase 2: Fullscreen Capture
open "litescreen://capture/fullscreen" 2>/dev/null || true
measure "2. Fullscreen Capture" 4

# Phase 3: History Browser
open "litescreen://open/history" 2>/dev/null || true
measure "3. Capture History" 4

# Phase 4: Settings Window
open "litescreen://settings" 2>/dev/null || true
measure "4. Preferences View" 4

# Phase 5: Post-test Idle
measure "5. Return to Idle" 5

echo "----------------------------------------------------------"
echo "🔍 Running macOS memory leak detector ('leaks $PID')..."
echo "----------------------------------------------------------"

LEAKS_OUT=$(leaks "$PID" 2>&1 || true)
LEAK_SUMMARY=$(echo "$LEAKS_OUT" | grep -i "leaks for" || echo "$LEAKS_OUT" | grep -i "leak" | head -n 3)

echo "$LEAK_SUMMARY"
echo "=========================================================="
