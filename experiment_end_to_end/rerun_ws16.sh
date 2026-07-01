#!/usr/bin/env bash

set -euo pipefail
trap '' HUP

# =============================================================================
# Re-run: ws=16G only (all workloads × all variants)
#   Repo: cxl-recordcache-WT_0517
#   Writes results into the original run directory, overwriting failed logs.
# =============================================================================

SSD_PATH="/path/to/data/cxl_test_tmp/cxl_test_ssd_wt"
CXL_DAX_DEVICE="/dev/dax0.3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/frontend"

TIMESTAMP="20260519_104913"
RESULT_DIR="$SCRIPT_DIR/run_${TIMESTAMP}"
MASTER_LOG="$RESULT_DIR/master_rerun_ws16.log"

WS=16
THETA=0.90
WORKLOADS=(b c a d f e)
VARIANTS=(two_level page_only lru dram_ssd dram_ssd_unconstrained)

WARMUP_LOOKUPS_TIER2=30000000
MEASURE_LOOKUPS=100000000

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

is_tier2() {
   case "$1" in
      d|e) return 0 ;;
      *)   return 1 ;;
   esac
}

get_warmup_lookups() {
   local wl="$1"
   if is_tier2 "$wl"; then
      echo "$WARMUP_LOOKUPS_TIER2"
   else
      echo 400000000
   fi
}

get_theta_tuning_flags() {
   cat <<'EOF'
--skew_threshold_ratio=0.08
--uniform_threshold_ratio=0.45
--max_per_page_visits=8000
--max_global_requests_window=2000000
--trigger_visit_histogram_update_size=1000000
EOF
}

COMMON_FLAGS_FIXED=(
   --test_payload_size_bytes="$PAYLOAD_SIZE_BYTES"
   --worker_threads="$WORKER_THREADS"
   --vi=true
   --test_measure_lookups="$MEASURE_LOOKUPS"
   --test_warmup_progress_interval="$WARMUP_PROGRESS_INTERVAL"
   --test_progress_interval="$PROGRESS_INTERVAL"
   --ssd_path="$SSD_PATH"
   --trunc=true
   --wal=true
)

TOTAL_EXPERIMENTS=$(( ${#WORKLOADS[@]} * ${#VARIANTS[@]} ))
CURRENT_EXPERIMENT=0

CXL_GIB=10.0
DRAM_TOTAL=2.5
DRAM_UNC=$(awk "BEGIN {printf \"%.3f\", 2.5 + 10.0}")

get_two_level_bp() {
   local wl="$1"
   if is_tier2 "$wl"; then echo 1.50; else echo 0.50; fi
}

get_two_level_rc() {
   local wl="$1"
   if is_tier2 "$wl"; then echo 1.00; else echo 2.00; fi
}

run_one() {
   local wl="$1" variant="$2"
   local theta="$THETA"

   CURRENT_EXPERIMENT=$((CURRENT_EXPERIMENT + 1))
   local binary="$BUILD_DIR/experiment_1_ycsb_${wl}"
   local result_file="$RESULT_DIR/result_ycsb${wl}_${variant}_theta${theta}_ws${WS}gib_${TIMESTAMP}.log"

   if [[ ! -x "$binary" ]]; then
      echo "[ERROR] binary not found: $binary"
      return 1
   fi

   local theta_flags=()
   while IFS= read -r line; do
      [[ -n "$line" ]] && theta_flags+=("$line")
   done < <(get_theta_tuning_flags)

   local warmup_lookups
   warmup_lookups="$(get_warmup_lookups "$wl")"
   local ws_float="16.0"

   local admission_mode=""
   local extra_flags=()

   case "$variant" in
      two_level)
         admission_mode="two_level"
         local bp rc
         bp="$(get_two_level_bp "$wl")"
         rc="$(get_two_level_rc "$wl")"
         extra_flags=(
            --cxl_tiering_enabled=true
            --cxl_gib="$CXL_GIB"
            --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS"
            --cxl_pp_threads="$CXL_PP_THREADS"
            --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS"
            --delay_admission_recordcache_threads_start=true
            --dram_buffer_pool_gib="$bp"
            --dram_recordcache_gib="$rc"
            --forward_epoch_thread="$FORWARD_EPOCH_THREAD"
            --sieve_eviction_thread="$SIEVE_EVICTION_THREAD"
            --record_cache_promote_thread="$RECORD_CACHE_PROMOTE_THREAD"
            "${theta_flags[@]}"
         )
         ;;
      page_only)
         admission_mode="page_only"
         extra_flags=(
            --cxl_tiering_enabled=true
            --cxl_gib="$CXL_GIB"
            --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS"
            --cxl_pp_threads="$CXL_PP_THREADS"
            --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS"
            --delay_admission_recordcache_threads_start=true
            --dram_buffer_pool_gib="$DRAM_TOTAL"
            "${theta_flags[@]}"
         )
         ;;
      lru)
         admission_mode="lru"
         extra_flags=(
            --cxl_tiering_enabled=true
            --cxl_gib="$CXL_GIB"
            --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS"
            --cxl_pp_threads="$CXL_PP_THREADS"
            --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS"
            --delay_admission_recordcache_threads_start=true
            --dram_buffer_pool_gib="$DRAM_TOTAL"
         )
         ;;
      dram_ssd)
         admission_mode="lru"
         extra_flags=(
            --cxl_tiering_enabled=false
            --dram_buffer_pool_gib="$DRAM_TOTAL"
            --pp_threads="$PP_THREADS"
         )
         ;;
      dram_ssd_unconstrained)
         admission_mode="lru"
         extra_flags=(
            --cxl_tiering_enabled=false
            --dram_buffer_pool_gib="$DRAM_UNC"
            --pp_threads="$PP_THREADS"
         )
         ;;
   esac

   echo ""
   echo "[RUN][$CURRENT_EXPERIMENT/$TOTAL_EXPERIMENTS] ws=${WS}G wl=$wl variant=$variant theta=$theta warmup=$warmup_lookups measure=$MEASURE_LOOKUPS"
   echo "[RUN] result -> $result_file"

   local wl_start_ts wl_end_ts wl_elapsed_sec wl_elapsed_min
   wl_start_ts=$(date +%s)
   local exit_code=0

   "$binary" \
      --test_admission_mode="$admission_mode" \
      --test_zipf_theta="$theta" \
      --test_warmup_lookups="$warmup_lookups" \
      --test_working_set_gib="$ws_float" \
      "${extra_flags[@]}" \
      "${COMMON_FLAGS_FIXED[@]}" \
      2>&1 | tee "$result_file" || exit_code=$?

   wl_end_ts=$(date +%s)
   wl_elapsed_sec=$((wl_end_ts - wl_start_ts))
   wl_elapsed_min=$(awk "BEGIN {printf \"%.2f\", $wl_elapsed_sec / 60.0}")

   if [[ "$exit_code" -ne 0 ]]; then
      echo "[WARN] ws=$WS wl=$wl variant=$variant exit code $exit_code (continuing)"
   fi

   echo "[TIME] ws=$WS wl=$wl variant=$variant theta=$theta elapsed: ${wl_elapsed_sec}s (${wl_elapsed_min} min)" \
      | tee -a "$result_file"

   echo "[INFO] cooldown ${COOLDOWN_SECONDS}s"
   sleep "$COOLDOWN_SECONDS"
}

main() {
   echo "============================================================"
   echo "  Re-run ws=16G (cxl-recordcache-WT_0517)"
   echo "  $(date)"
   echo "============================================================"
   echo "[INFO] result_dir  = ${RESULT_DIR}"
   echo "[INFO] ssd_path    = ${SSD_PATH}"
   echo "[INFO] dax_device  = ${CXL_DAX_DEVICE}"
   echo "[INFO] total_exps  = ${TOTAL_EXPERIMENTS}"
   echo ""

   if [[ ! -e "$CXL_DAX_DEVICE" ]]; then
      echo "[ERROR] dax device $CXL_DAX_DEVICE not found"; exit 1
   fi
   if command -v lsof >/dev/null 2>&1; then
      local stale
      stale="$(lsof -t "$CXL_DAX_DEVICE" 2>/dev/null || true)"
      if [[ -n "$stale" ]]; then
         echo "[ERROR] dax device $CXL_DAX_DEVICE busy (pids: $stale)"; exit 1
      fi
   fi

   local OVERALL_START
   OVERALL_START=$(date +%s)

   for wl in "${WORKLOADS[@]}"; do
      for variant in "${VARIANTS[@]}"; do
         run_one "$wl" "$variant"
      done
   done

   local OVERALL_END OVERALL_SEC OVERALL_MIN OVERALL_HR
   OVERALL_END=$(date +%s)
   OVERALL_SEC=$((OVERALL_END - OVERALL_START))
   OVERALL_MIN=$(awk "BEGIN {printf \"%.1f\", $OVERALL_SEC / 60.0}")
   OVERALL_HR=$(awk "BEGIN {printf \"%.2f\", $OVERALL_SEC / 3600.0}")

   echo ""
   echo "============================================================"
   echo "  All ws=16G experiments completed"
   echo "============================================================"
   echo "[DONE] result_dir   = ${RESULT_DIR}"
   echo "[TIME] total elapsed = ${OVERALL_SEC}s (${OVERALL_MIN} min, ${OVERALL_HR} hr)"
}

main 2>&1 | tee "$MASTER_LOG"
