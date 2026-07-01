#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# TPC-C Test for cxl-recordcache-dev (ReadOnly mode, two_level admission)
#
# Purpose: Verify whether slab rescue (tryRescueSlabForAllocator) triggers
#          under TPC-C's variable record sizes, causing lock contention.
#
# Based on: exp7_group1_BCD_tpcc.sh parameters for two_level_readonly
# =============================================================================

BINARY="/path/to/project/cxl-recordcache-dev/build/frontend/tpcc"
SSD_PATH="${SSD_PATH:-/path/to/data/cxl_test_tmp/tpcc_readonly_test}"
CXL_DAX_DEVICE="${CXL_DAX_DEVICE:-/dev/dax0.6}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$SCRIPT_DIR/run_${TIMESTAMP}_tpcc_readonly"
mkdir -p "$RESULT_DIR"

# Memory config (same as exp7 two_level_readonly for workload a/b/c/f tier)
WS_GIB=23.0
CXL_GIB=18.0
DRAM_BP_GIB=0.43
DRAM_RC_GIB=2.57

# TPC-C config
TPCC_WAREHOUSE_COUNT=100
WARMUP_SECONDS=120
MEASURE_SECONDS=180

# Threading
WORKER_THREADS=20
PP_THREADS=1
CXL_PP_THREADS=1
TWO_LEVEL_ADMISSION_THREADS=2
FORWARD_EPOCH_THREAD=1
SIEVE_EVICTION_THREAD=1
RECORD_CACHE_PROMOTE_THREAD=4

echo "============================================================"
echo "  TPC-C ReadOnly (two_level) — Slab Rescue Verification"
echo "============================================================"
echo "[INFO] binary           = $BINARY"
echo "[INFO] ssd_path         = $SSD_PATH"
echo "[INFO] cxl_device       = $CXL_DAX_DEVICE"
echo "[INFO] warehouses       = $TPCC_WAREHOUSE_COUNT"
echo "[INFO] warmup           = ${WARMUP_SECONDS}s"
echo "[INFO] measure          = ${MEASURE_SECONDS}s"
echo "[INFO] workers          = $WORKER_THREADS"
echo "[INFO] dram_bp          = ${DRAM_BP_GIB} GiB"
echo "[INFO] dram_rc          = ${DRAM_RC_GIB} GiB"
echo "[INFO] result_dir       = $RESULT_DIR"
echo ""

if [[ ! -x "$BINARY" ]]; then
    echo "[ERROR] binary not found: $BINARY"
    exit 1
fi

if [[ ! -e "$CXL_DAX_DEVICE" ]]; then
    echo "[ERROR] dax device not found: $CXL_DAX_DEVICE"
    exit 1
fi

rm -f "$SSD_PATH"

RESULT_FILE="$RESULT_DIR/tpcc_two_level_readonly.log"

echo "[START] $(date '+%Y-%m-%d %H:%M:%S')"
START_TS=$(date +%s)

"$BINARY" \
    --tpcc_warehouse_count="$TPCC_WAREHOUSE_COUNT" \
    --warmup_for_seconds="$WARMUP_SECONDS" \
    --run_for_seconds="$MEASURE_SECONDS" \
    --worker_threads="$WORKER_THREADS" \
    --vi=true --wal=true --trunc=true \
    --ssd_path="$SSD_PATH" \
    --admission_mode="two_level" \
    --cxl_tiering_enabled=true \
    --cxl_gib="$CXL_GIB" \
    --cxl_dax_device_path="$CXL_DAX_DEVICE" \
    --pp_threads="$PP_THREADS" \
    --cxl_pp_threads="$CXL_PP_THREADS" \
    --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS" \
    --delay_admission_recordcache_threads_start=true \
    --dram_buffer_pool_gib="$DRAM_BP_GIB" \
    --dram_recordcache_gib="$DRAM_RC_GIB" \
    --forward_epoch_thread="$FORWARD_EPOCH_THREAD" \
    --sieve_eviction_thread="$SIEVE_EVICTION_THREAD" \
    --record_cache_promote_thread="$RECORD_CACHE_PROMOTE_THREAD" \
    2>&1 | tee "$RESULT_FILE" || true

ELAPSED=$(( $(date +%s) - START_TS ))
echo ""
echo "[DONE] elapsed=${ELAPSED}s ($(awk "BEGIN{printf \"%.1f\", $ELAPSED/60.0}") min)"
echo "[RESULT] $RESULT_FILE"
echo ""

# Check if slab rescue was triggered
RESCUE_COUNT=$(grep -c "SLAB-RESCUE" "$RESULT_FILE" 2>/dev/null || true)
RESCUE_COUNT=${RESCUE_COUNT:-0}
BAD_ALLOC_COUNT=$(grep -c "bad_alloc" "$RESULT_FILE" 2>/dev/null || true)
BAD_ALLOC_COUNT=${BAD_ALLOC_COUNT:-0}

echo "============================================================"
echo "  Slab Rescue Diagnosis"
echo "============================================================"
echo "  SLAB-RESCUE triggered: $RESCUE_COUNT times"
echo "  bad_alloc raised:      $BAD_ALLOC_COUNT times"
if [[ "$RESCUE_COUNT" -gt 0 ]]; then
    echo ""
    echo "  [WARNING] Slab rescue DID trigger — promote thread took"
    echo "  unique_lock on ALL shards, likely blocking frontend workers."
    echo ""
    grep "SLAB-RESCUE" "$RESULT_FILE" | tail -10
fi
echo "============================================================"
