#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# Perf Profiling for TPC-C ReadOnly test
#
# Attach to the tpcc process, record + stat during measurement phase.
# Output to /data1 to avoid filling /home.
# =============================================================================

FLAMEGRAPH_DIR="/path/to/project/FlameGraph"
PERF_DIR="/path/to/data/cxl_test_tmp/perf_tpcc_readonly_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$PERF_DIR"

BINARY_NAME="tpcc"
PERF_FREQ=499
POLL_INTERVAL=2
IDLE_TIMEOUT=60

echo "============================================================"
echo "  Perf Profiling — TPC-C ReadOnly"
echo "============================================================"
echo "[INFO] perf_dir   = $PERF_DIR"
echo "[INFO] frequency  = $PERF_FREQ Hz"
echo "[INFO] target     = $BINARY_NAME"
echo ""
echo "[SCAN] Waiting for $BINARY_NAME process..."

# Wait for tpcc process to appear
idle=0
PID=""
while [[ -z "$PID" ]]; do
    PID=$(pgrep -x "$BINARY_NAME" 2>/dev/null | head -1 || true)
    if [[ -z "$PID" ]]; then
        sleep "$POLL_INTERVAL"
        idle=$((idle + POLL_INTERVAL))
        if [[ $idle -ge $IDLE_TIMEOUT ]]; then
            echo "[EXIT] No $BINARY_NAME process found after ${IDLE_TIMEOUT}s"
            exit 1
        fi
    fi
done

echo "[FOUND] PID=$PID"
echo ""

PREFIX="$PERF_DIR/tpcc_two_level_readonly"

# Start perf stat
echo "[ATTACH] perf stat on PID=$PID"
perf stat -e cycles,instructions,cache-references,cache-misses,branch-misses,page-faults \
    -p "$PID" 2>"${PREFIX}.perf_stat" &
STAT_PID=$!

# Start perf record (lower stack depth than before to avoid 74G files)
echo "[ATTACH] perf record on PID=$PID (freq=$PERF_FREQ, fp stack)"
perf record -g -F "$PERF_FREQ" --call-graph fp \
    -p "$PID" -o "${PREFIX}.perf.data" 2>/dev/null &
RECORD_PID=$!

echo "[WAIT] Profiling until $BINARY_NAME exits..."
echo ""

# Wait for tpcc to finish
while kill -0 "$PID" 2>/dev/null; do
    sleep 5
done

echo "[DONE] $BINARY_NAME exited"
sleep 2

# Stop perf
kill "$STAT_PID" 2>/dev/null || true
kill "$RECORD_PID" 2>/dev/null || true
wait "$STAT_PID" 2>/dev/null || true
wait "$RECORD_PID" 2>/dev/null || true

echo ""
echo "[STAT] ${PREFIX}.perf_stat"
cat "${PREFIX}.perf_stat"
echo ""

# Generate flamegraph
if [[ -f "${PREFIX}.perf.data" ]] && [[ -s "${PREFIX}.perf.data" ]]; then
    echo "[FLAME] Generating flamegraph..."
    perf script -i "${PREFIX}.perf.data" 2>/dev/null | \
        "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" --all > "${PREFIX}.folded" 2>/dev/null || true

    if [[ -s "${PREFIX}.folded" ]]; then
        "$FLAMEGRAPH_DIR/flamegraph.pl" \
            --title "TPC-C ReadOnly two_level (100 warehouses, 20 workers)" \
            --width 1800 \
            "${PREFIX}.folded" > "${PREFIX}.svg" 2>/dev/null || true
        echo "[FLAME] → ${PREFIX}.svg"
    fi

    perf report -i "${PREFIX}.perf.data" --stdio --no-children \
        -s symbol --percent-limit 0.5 2>/dev/null | head -80 > "${PREFIX}.top_functions.txt" || true
    echo "[REPORT] → ${PREFIX}.top_functions.txt"

    # Specific check: slab rescue in call stacks
    RESCUE_SAMPLES=$(grep -c "tryRescueSlab" "${PREFIX}.folded" 2>/dev/null || echo "0")
    echo ""
    echo "============================================================"
    echo "  Slab Rescue in Perf Samples: $RESCUE_SAMPLES stacks"
    echo "============================================================"
    if [[ "$RESCUE_SAMPLES" -gt 0 ]]; then
        echo "  [!] tryRescueSlabForAllocator appeared in call stacks"
        grep "tryRescueSlab" "${PREFIX}.folded" | awk -F' ' '{sum+=$NF} END {printf "  Total cycles in rescue: %d\n", sum}'
    else
        echo "  [OK] No slab rescue detected in perf samples"
    fi
else
    echo "[WARN] No perf data captured"
fi

echo ""
echo "[RESULTS] $PERF_DIR"
ls -lh "$PERF_DIR"/
