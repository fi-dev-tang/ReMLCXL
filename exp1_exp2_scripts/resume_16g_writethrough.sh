#!/usr/bin/env bash

set -euo pipefail
trap '' HUP

# =============================================================================
# Resume 16G experiments — WriteThrough (CellarCXL-WriteThrough)
#
# Runs the 18 missing 16G experiments that didn't complete in the original run.
# Results saved to a new timestamped directory (does not touch old results).
#
# Usage:
#   cd /path/to/project/CellarCXL_experiments
#   nohup bash exp1_exp2_scripts/resume_16g_writethrough.sh &
# =============================================================================

# --- Repo / device config (same as original WT script) ---
SSD_PATH="/path/to/data/cxl_test_tmp/exp1_exp2_writeThrough"
CXL_DAX_DEVICE="/dev/dax0.2"
REPO_ROOT="/path/to/project/CellarCXL-WriteThrough"
BUILD_DIR="$REPO_ROOT/build/frontend"

# --- Output ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$SCRIPT_DIR/resume_16g_wt_${TIMESTAMP}"
mkdir -p "$RESULT_DIR"
MASTER_LOG="$RESULT_DIR/master.log"

# --- Fixed 16G config ---
WS=16
WS_FLOAT=16.0
THETA=0.90
CXL_GIB=10.0
DRAM_TOTAL=2.5
DRAM_UNC=12.5

WARMUP_TIER1=400000000
WARMUP_TIER2=30000000
MEASURE=100000000

# --- Threading ---
WORKER_THREADS=8
PP_THREADS=1
CXL_PP_THREADS=1
TWO_LEVEL_ADMISSION_THREADS=2
FORWARD_EPOCH_THREAD=1
SIEVE_EVICTION_THREAD=1
RECORD_CACHE_PROMOTE_THREAD=4
PAYLOAD_SIZE=100
COOLDOWN=30

THETA_FLAGS=(
   --skew_threshold_ratio=0.08
   --uniform_threshold_ratio=0.45
   --max_per_page_visits=8000
   --max_global_requests_window=2000000
   --trigger_visit_histogram_update_size=1000000
)

COMMON_FLAGS=(
   --test_payload_size_bytes="$PAYLOAD_SIZE"
   --worker_threads="$WORKER_THREADS"
   --vi=true
   --test_measure_lookups="$MEASURE"
   --test_warmup_progress_interval=2000000
   --test_progress_interval=1000000
   --ssd_path="$SSD_PATH"
   --trunc=true
   --wal=true
)

# --- Remaining: (workload variant) pairs ---
REMAINING=(
   "a lru"
   "a dram_ssd"
   "a dram_ssd_unconstrained"
   "d two_level"
   "d page_only"
   "d lru"
   "d dram_ssd"
   "d dram_ssd_unconstrained"
   "e two_level"
   "e page_only"
   "e lru"
   "e dram_ssd"
   "e dram_ssd_unconstrained"
   "f two_level"
   "f page_only"
   "f lru"
   "f dram_ssd"
   "f dram_ssd_unconstrained"
)

TOTAL=${#REMAINING[@]}
CURRENT=0
PASS=0
FAIL=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== Resume 16G WriteThrough ==="
log "timestamp=$TIMESTAMP result_dir=$RESULT_DIR dax=$CXL_DAX_DEVICE experiments=$TOTAL"

if [[ ! -e "$CXL_DAX_DEVICE" ]]; then
   echo "[ERROR] DAX device $CXL_DAX_DEVICE not found"; exit 1
fi
for wl in a b c d e f; do
   [[ ! -x "$BUILD_DIR/experiment_1_ycsb_${wl}" ]] && echo "[WARN] missing: experiment_1_ycsb_${wl}"
done
if command -v lsof >/dev/null 2>&1; then
   stale="$(lsof -t "$CXL_DAX_DEVICE" 2>/dev/null || true)"
   if [[ -n "$stale" ]]; then
      echo "[ERROR] DAX busy (pids: $stale)"; exit 1
   fi
fi

OVERALL_START=$(date +%s)

for pair in "${REMAINING[@]}"; do
   wl="${pair%% *}"
   variant="${pair##* }"
   CURRENT=$((CURRENT + 1))

   binary="$BUILD_DIR/experiment_1_ycsb_${wl}"
   result_file="$RESULT_DIR/result_ycsb${wl}_${variant}_theta${THETA}_ws${WS}gib_${TIMESTAMP}.log"

   case "$wl" in
      d|e) warmup="$WARMUP_TIER2" ;;
      *)   warmup="$WARMUP_TIER1" ;;
   esac

   admission_mode=""
   extra_flags=()

   case "$variant" in
      two_level)
         admission_mode="two_level"
         case "$wl" in e) bp=1.50; rc=1.00 ;; *) bp=0.50; rc=2.00 ;; esac
         extra_flags=(
            --cxl_tiering_enabled=true --cxl_gib="$CXL_GIB" --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS" --cxl_pp_threads="$CXL_PP_THREADS"
            --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS"
            --delay_admission_recordcache_threads_start=true
            --dram_buffer_pool_gib="$bp" --dram_recordcache_gib="$rc"
            --forward_epoch_thread="$FORWARD_EPOCH_THREAD" --sieve_eviction_thread="$SIEVE_EVICTION_THREAD"
            --record_cache_promote_thread="$RECORD_CACHE_PROMOTE_THREAD" "${THETA_FLAGS[@]}"
         ) ;;
      page_only)
         admission_mode="page_only"
         extra_flags=(
            --cxl_tiering_enabled=true --cxl_gib="$CXL_GIB" --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS" --cxl_pp_threads="$CXL_PP_THREADS"
            --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS"
            --delay_admission_recordcache_threads_start=true
            --dram_buffer_pool_gib="$DRAM_TOTAL" "${THETA_FLAGS[@]}"
         ) ;;
      lru)
         admission_mode="lru"
         extra_flags=(
            --cxl_tiering_enabled=true --cxl_gib="$CXL_GIB" --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS" --cxl_pp_threads="$CXL_PP_THREADS"
            --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS"
            --delay_admission_recordcache_threads_start=true
            --dram_buffer_pool_gib="$DRAM_TOTAL"
         ) ;;
      dram_ssd)
         admission_mode="lru"
         extra_flags=( --cxl_tiering_enabled=false --dram_buffer_pool_gib="$DRAM_TOTAL" --pp_threads="$PP_THREADS" ) ;;
      dram_ssd_unconstrained)
         admission_mode="lru"
         extra_flags=( --cxl_tiering_enabled=false --dram_buffer_pool_gib="$DRAM_UNC" --pp_threads="$PP_THREADS" ) ;;
   esac

   echo ""
   echo "============================================================"
   log "[$CURRENT/$TOTAL] ws=${WS}G wl=$wl variant=$variant warmup=$warmup"
   echo "============================================================"

   rm -f "$SSD_PATH"
   start_ts=$(date +%s)
   exit_code=0

   "$binary" \
      --test_admission_mode="$admission_mode" \
      --test_zipf_theta="$THETA" \
      --test_warmup_lookups="$warmup" \
      --test_working_set_gib="$WS_FLOAT" \
      "${extra_flags[@]}" \
      "${COMMON_FLAGS[@]}" \
      2>&1 | tee "$result_file" || exit_code=$?

   elapsed=$(( $(date +%s) - start_ts ))
   elapsed_min=$(awk "BEGIN {printf \"%.1f\", $elapsed / 60.0}")

   if [[ "$exit_code" -ne 0 ]]; then
      echo "[WARN] ws=$WS wl=$wl variant=$variant exit=$exit_code (${elapsed_min} min)"
      FAIL=$((FAIL + 1))
   else
      echo "[PASS] ws=$WS wl=$wl variant=$variant (${elapsed_min} min)"
      PASS=$((PASS + 1))
   fi

   echo "[TIME] ws=$WS wl=$wl variant=$variant theta=$THETA elapsed: ${elapsed}s (${elapsed_min} min)" | tee -a "$result_file"
   sleep "$COOLDOWN"
done

OVERALL_SEC=$(( $(date +%s) - OVERALL_START ))
OVERALL_HR=$(awk "BEGIN {printf \"%.2f\", $OVERALL_SEC / 3600.0}")

echo ""
echo "============================================================"
echo "  RESUME 16G WriteThrough COMPLETE  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo "[INFO] pass=$PASS fail=$FAIL / $TOTAL"
echo "[INFO] elapsed = ${OVERALL_SEC}s (${OVERALL_HR} hr)"
echo "[INFO] results in: $RESULT_DIR"
