#!/usr/bin/env bash

set -euo pipefail
trap '' HUP

# =============================================================================
# Restore Baseline 0519 — ReadOnly two_level only
#   Quick smoke test to compare current build against 0519 QPS baselines.
#
# 0519 Baselines (ReadOnly, two_level, ws=4, theta=0.90):
#   YCSB-A: QPS=129,639  RC_HR=1.5%
#   YCSB-B: QPS=316,254  RC_HR=19.6%
#   YCSB-C: QPS=1,122,075  RC_HR=87.0%
# =============================================================================

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
SSD_PATH="${SSD_PATH:-/path/to/data/cxl_test_tmp/exp1_exp2_readonly}"
CXL_DAX_DEVICE="${CXL_DAX_DEVICE:-/dev/dax0.1}"

REPO_ROOT="/path/to/project/cxl-recordcache-dev"
BUILD_DIR="$REPO_ROOT/build/frontend"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$SCRIPT_DIR/run_${TIMESTAMP}_ReadOnly"
mkdir -p "$RESULT_DIR"
MASTER_LOG="$RESULT_DIR/master.log"

# Matrix: only two_level, ws=4 (fast), all 6 workloads
WORKING_SETS=(4)
THETA=0.90
WORKLOADS=(b c a d f e)
VARIANT="two_level"

# Lookup config
WARMUP_LOOKUPS_TIER2=30000000
MEASURE_LOOKUPS=100000000

# Threading
WORKER_THREADS=8
PP_THREADS=1
CXL_PP_THREADS=1
TWO_LEVEL_ADMISSION_THREADS=2
FORWARD_EPOCH_THREAD=1
SIEVE_EVICTION_THREAD=1
RECORD_CACHE_PROMOTE_THREAD=4

PAYLOAD_SIZE_BYTES=100
PROGRESS_INTERVAL=1000000
WARMUP_PROGRESS_INTERVAL=2000000
COOLDOWN_SECONDS=30

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
is_tier2() {
   case "$1" in
      d|e) return 0 ;;
      *)   return 1 ;;
   esac
}

get_warmup_tier1() {
   case "$1" in
      4)  echo 100000000 ;;
      8)  echo 200000000 ;;
      16) echo 400000000 ;;
   esac
}

get_warmup_lookups() {
   local ws="$1" wl="$2"
   if is_tier2 "$wl"; then
      echo "$WARMUP_LOOKUPS_TIER2"
   else
      get_warmup_tier1 "$ws"
   fi
}

get_cxl_gib() {
   case "$1" in
      4)  echo 2.5 ;;
      8)  echo 5.0 ;;
      16) echo 10.0 ;;
   esac
}

get_two_level_bp() {
   local ws="$1" wl="$2"
   if is_tier2 "$wl"; then
      case "$ws" in
         4)  echo 0.40 ;;
         8)  echo 0.80 ;;
         16) echo 1.50 ;;
      esac
   else
      case "$ws" in
         4)  echo 0.10 ;;
         8)  echo 0.20 ;;
         16) echo 0.50 ;;
      esac
   fi
}

get_two_level_rc() {
   local ws="$1" wl="$2"
   if is_tier2 "$wl"; then
      case "$ws" in
         4)  echo 0.20 ;;
         8)  echo 0.40 ;;
         16) echo 1.00 ;;
      esac
   else
      case "$ws" in
         4)  echo 0.50 ;;
         8)  echo 1.00 ;;
         16) echo 2.00 ;;
      esac
   fi
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
if [[ ! -e "$CXL_DAX_DEVICE" ]]; then
   echo "[ERROR] dax device $CXL_DAX_DEVICE not found"
   exit 1
fi

for wl in "${WORKLOADS[@]}"; do
   if [[ ! -x "$BUILD_DIR/experiment_1_ycsb_${wl}" ]]; then
      echo "[ERROR] binary not found: $BUILD_DIR/experiment_1_ycsb_${wl}"
      exit 1
   fi
done

if command -v lsof >/dev/null 2>&1; then
   stale="$(lsof -t "$CXL_DAX_DEVICE" 2>/dev/null || true)"
   if [[ -n "$stale" ]]; then
      echo "[ERROR] dax device $CXL_DAX_DEVICE busy (pids: $stale)"
      exit 1
   fi
fi

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
run_one() {
   local ws="$1" wl="$2"
   local theta="$THETA"
   local binary="$BUILD_DIR/experiment_1_ycsb_${wl}"
   local result_file="$RESULT_DIR/result_ycsb${wl}_two_level_theta${theta}_ws${ws}gib_${TIMESTAMP}.log"

   local warmup_lookups
   warmup_lookups="$(get_warmup_lookups "$ws" "$wl")"

   local cxl_gib bp rc ws_float
   cxl_gib="$(get_cxl_gib "$ws")"
   bp="$(get_two_level_bp "$ws" "$wl")"
   rc="$(get_two_level_rc "$ws" "$wl")"
   ws_float=$(awk "BEGIN {printf \"%.1f\", $ws}")

   echo ""
   echo "[RUN] ws=${ws}G wl=$wl variant=two_level theta=$theta warmup=$warmup_lookups measure=$MEASURE_LOOKUPS"
   echo "[RUN] result -> $result_file"

   local wl_start_ts wl_end_ts wl_elapsed_sec wl_elapsed_min
   wl_start_ts=$(date +%s)
   local exit_code=0

   "$binary" \
      --test_admission_mode="two_level" \
      --test_zipf_theta="$theta" \
      --test_warmup_lookups="$warmup_lookups" \
      --test_working_set_gib="$ws_float" \
      --cxl_tiering_enabled=true \
      --cxl_gib="$cxl_gib" \
      --cxl_dax_device_path="$CXL_DAX_DEVICE" \
      --pp_threads="$PP_THREADS" \
      --cxl_pp_threads="$CXL_PP_THREADS" \
      --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS" \
      --delay_admission_recordcache_threads_start=true \
      --dram_buffer_pool_gib="$bp" \
      --dram_recordcache_gib="$rc" \
      --forward_epoch_thread="$FORWARD_EPOCH_THREAD" \
      --sieve_eviction_thread="$SIEVE_EVICTION_THREAD" \
      --record_cache_promote_thread="$RECORD_CACHE_PROMOTE_THREAD" \
      --skew_threshold_ratio=0.08 \
      --uniform_threshold_ratio=0.45 \
      --max_per_page_visits=8000 \
      --max_global_requests_window=2000000 \
      --trigger_visit_histogram_update_size=1000000 \
      --test_payload_size_bytes="$PAYLOAD_SIZE_BYTES" \
      --worker_threads="$WORKER_THREADS" \
      --vi=true \
      --test_measure_lookups="$MEASURE_LOOKUPS" \
      --test_warmup_progress_interval="$WARMUP_PROGRESS_INTERVAL" \
      --test_progress_interval="$PROGRESS_INTERVAL" \
      --ssd_path="$SSD_PATH" \
      --trunc=true \
      --wal=true \
      2>&1 | tee "$result_file" || exit_code=$?

   wl_end_ts=$(date +%s)
   wl_elapsed_sec=$((wl_end_ts - wl_start_ts))
   wl_elapsed_min=$(awk "BEGIN {printf \"%.2f\", $wl_elapsed_sec / 60.0}")

   if [[ "$exit_code" -ne 0 ]]; then
      echo "[WARN] ws=$ws wl=$wl exit code $exit_code"
   fi

   echo "[TIME] ws=$ws wl=$wl variant=two_level theta=$theta elapsed: ${wl_elapsed_sec}s (${wl_elapsed_min} min)" \
      | tee -a "$result_file"

   echo "[INFO] cooldown ${COOLDOWN_SECONDS}s"
   sleep "$COOLDOWN_SECONDS"
}

main() {
   echo "============================================================"
   echo "  Restore Baseline 0519 — ReadOnly two_level smoke test"
   echo "============================================================"
   echo "[INFO] timestamp       = ${TIMESTAMP}"
   echo "[INFO] result_dir      = ${RESULT_DIR}"
   echo "[INFO] repo            = cxl-recordcache-dev"
   echo "[INFO] branch          = optimization_read_only_record_cache_0501"
   echo "[INFO] ssd_path        = ${SSD_PATH}"
   echo "[INFO] cxl_dax_device  = ${CXL_DAX_DEVICE}"
   echo "[INFO] working_sets    = ${WORKING_SETS[*]}"
   echo "[INFO] workloads       = ${WORKLOADS[*]}"
   echo "[INFO] variant         = two_level only"
   echo ""

   local OVERALL_START
   OVERALL_START=$(date +%s)

   for ws in "${WORKING_SETS[@]}"; do
      echo ""
      echo "============================================================"
      echo "  WS=${ws} GiB"
      echo "============================================================"
      for wl in "${WORKLOADS[@]}"; do
         run_one "$ws" "$wl"
      done
   done

   local OVERALL_END OVERALL_SEC OVERALL_MIN
   OVERALL_END=$(date +%s)
   OVERALL_SEC=$((OVERALL_END - OVERALL_START))
   OVERALL_MIN=$(awk "BEGIN {printf \"%.1f\", $OVERALL_SEC / 60.0}")

   echo ""
   echo "============================================================"
   echo "  All done — total: ${OVERALL_SEC}s (${OVERALL_MIN} min)"
   echo "============================================================"

   # Print comparison table
   echo ""
   echo "=== QPS Comparison vs 0519 Baseline ==="
   printf "%-8s %-12s %-12s %-10s\n" "WL" "0519_QPS" "Current_QPS" "Delta"
   echo "----------------------------------------------"
   for f in "$RESULT_DIR"/result_ycsb*_two_level_*.log; do
      local wl_name current_qps
      wl_name=$(basename "$f" | sed 's/result_ycsb\(.\)_.*/\1/')
      current_qps=$(grep "mode=two_level.*QPS=" "$f" 2>/dev/null | tail -1 | sed 's/.*QPS=\([0-9.]*\).*/\1/' || echo "N/A")
      if [[ "$current_qps" != "N/A" && -n "$current_qps" ]]; then
         printf "%-8s %-12s %-12s\n" "YCSB-${wl_name^^}" "see_0519" "$current_qps"
      fi
   done
}

main 2>&1 | tee "$MASTER_LOG"
