#!/usr/bin/env bash

set -euo pipefail
trap '' HUP

# =============================================================================
# Resume: run the 9 missing perf_record experiments from the crashed
# run_20260626_204219_exp5_perf (which failed at experiment 117/125 due to
# /home disk full).
#
# Missing:
#   ycsb_f: two_level_wt, bf-tree, tiered-indexing-zxj, hybried-tier-asplos2025
#   ycsb_e: two_level_readonly, two_level_wt, bf-tree, tiered-indexing-zxj, hybried-tier-asplos2025
#
# Results are written INTO the existing run directory so all data stays together.
# perf.data goes to /data1; folded inline after each run.
# =============================================================================

# -----------------------------------------------------------------------------
# Existing run directory (where the 115 successful results already live)
# -----------------------------------------------------------------------------
EXISTING_RUN_DIR="/path/to/project/CellarCXL_experiments/exp5_profile_scrips/run_20260626_204219_exp5_perf"
RESULT_DIR="$EXISTING_RUN_DIR"
MASTER_LOG="$RESULT_DIR/master_resume.log"

# perf.data on /data1 (same policy as the fixed exp5_perf_profiling.sh)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FLAMEGRAPH_DIR="/path/to/data/cxl_test_tmp/exp5_perf_profiling_data/resume_${TIMESTAMP}"
FOLDED_DIR="$RESULT_DIR/folded_stacks"
PERF_REPORT_DIR="$RESULT_DIR/perf_reports"
FLAMEGRAPH_TOOL_DIR="/path/to/project/FlameGraph"
mkdir -p "$FLAMEGRAPH_DIR" "$FOLDED_DIR" "$PERF_REPORT_DIR"

# -----------------------------------------------------------------------------
# Config (identical to exp5_perf_profiling.sh)
# -----------------------------------------------------------------------------
BUILD_DIR_WT="/path/to/project/CellarCXL-WriteThrough/build/frontend"
BUILD_DIR_RO="/path/to/project/CellarCXL-ReadOnly/build/frontend"

SSD_PATH="/path/to/data/cxl_test_tmp/exp5_perf_profiling"
CXL_DAX_DEVICE="/dev/dax0.8"

MODES=(two_level_readonly two_level_wt bf-tree tiered-indexing-zxj hybried-tier-asplos2025)
RECORD_THETA=0.90
PERF_RECORD_FREQ=99

WS_GIB=23.0
CXL_GIB=18.0
DRAM_TOTAL=3.0

TWO_LEVEL_BP_ABCF=0.43
TWO_LEVEL_RC_ABCF=2.57
TWO_LEVEL_BP_DE=2.57
TWO_LEVEL_RC_DE=0.43
BASELINE_BP=3.0

WARMUP_LOOKUPS_TIER1=800000000
WARMUP_LOOKUPS_TIER2=50000000
RECORD_MEASURE_LOOKUPS=50000000

WORKER_THREADS=20
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
# Helpers (copied from exp5_perf_profiling.sh)
# -----------------------------------------------------------------------------
log_info() { echo "[INFO] $(date '+%H:%M:%S') $1" | tee -a "$MASTER_LOG"; }

is_tier2_warmup() { case "$1" in d|e) return 0 ;; *) return 1 ;; esac; }
is_tier2_bp_rc()  { case "$1" in e) return 0 ;; *) return 1 ;; esac; }

get_build_dir() {
   case "$1" in
      two_level_readonly) echo "$BUILD_DIR_RO" ;;
      *)                  echo "$BUILD_DIR_WT" ;;
   esac
}

get_admission_mode() {
   case "$1" in
      two_level_readonly|two_level_wt) echo "two_level" ;;
      *) echo "$1" ;;
   esac
}

build_mode_flags() {
   local mode="$1" wl="$2"
   local admission_mode
   admission_mode="$(get_admission_mode "$mode")"

   local bp_gib rc_gib
   case "$mode" in
      two_level_readonly|two_level_wt)
         if is_tier2_bp_rc "$wl"; then
            bp_gib="$TWO_LEVEL_BP_DE"
            rc_gib="$TWO_LEVEL_RC_DE"
         else
            bp_gib="$TWO_LEVEL_BP_ABCF"
            rc_gib="$TWO_LEVEL_RC_ABCF"
         fi
         MODE_FLAGS=(
            --test_admission_mode="$admission_mode"
            --cxl_tiering_enabled=true
            --cxl_gib="$CXL_GIB"
            --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS"
            --cxl_pp_threads="$CXL_PP_THREADS"
            --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS"
            --delay_admission_recordcache_threads_start=true
            --dram_buffer_pool_gib="$bp_gib"
            --dram_recordcache_gib="$rc_gib"
            --forward_epoch_thread="$FORWARD_EPOCH_THREAD"
            --sieve_eviction_thread="$SIEVE_EVICTION_THREAD"
            --record_cache_promote_thread="$RECORD_CACHE_PROMOTE_THREAD"
         )
         ;;
      bf-tree)
         MODE_FLAGS=(
            --test_admission_mode=bf-tree
            --cxl_tiering_enabled=true
            --cxl_gib="$CXL_GIB"
            --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS"
            --cxl_pp_threads="$CXL_PP_THREADS"
            --dram_buffer_pool_gib="$BASELINE_BP"
            --dram_recordcache_gib=0.0
         )
         ;;
      tiered-indexing-zxj)
         MODE_FLAGS=(
            --test_admission_mode=tiered-indexing-zxj
            --cxl_tiering_enabled=true
            --cxl_gib="$CXL_GIB"
            --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS"
            --cxl_pp_threads="$CXL_PP_THREADS"
            --dram_buffer_pool_gib="$BASELINE_BP"
            --dram_recordcache_gib=0.0
            --vi_fremove=true
         )
         ;;
      hybried-tier-asplos2025)
         MODE_FLAGS=(
            --test_admission_mode=hybried-tier-asplos2025
            --cxl_tiering_enabled=true
            --cxl_gib="$CXL_GIB"
            --cxl_dax_device_path="$CXL_DAX_DEVICE"
            --pp_threads="$PP_THREADS"
            --cxl_pp_threads="$CXL_PP_THREADS"
            --two_level_admission_threads="$TWO_LEVEL_ADMISSION_THREADS"
            --delay_admission_recordcache_threads_start=true
            --dram_buffer_pool_gib="$BASELINE_BP"
            --dram_recordcache_gib=0.0
         )
         ;;
   esac
}

# Fold perf.data → .folded + perf report, then delete raw perf.data
fold_perf_data() {
   local perf_data="$1"
   local base folded report flamegraph_tool

   base="$(basename "$perf_data" .data)"
   folded="$FOLDED_DIR/${base}.folded"
   report="$PERF_REPORT_DIR/${base}.txt"
   flamegraph_tool="$FLAMEGRAPH_TOOL_DIR/stackcollapse-perf.pl"

   if [[ ! -f "$perf_data" ]] || [[ ! -s "$perf_data" ]]; then
      log_info "perf.data missing or empty, skipping fold"
      return 0
   fi
   if [[ ! -x "$flamegraph_tool" ]]; then
      log_info "stackcollapse-perf.pl not found, keeping raw perf.data"
      return 0
   fi

   log_info "folding perf.data → ${base}.folded"
   if perf script -i "$perf_data" 2>/dev/null \
      | "$flamegraph_tool" --all > "$folded" 2>/dev/null; then
      perf report -i "$perf_data" --stdio --no-children --sort comm,dso,symbol 2>/dev/null \
         | head -80 > "$report" || true
      local folded_size
      folded_size="$(du -sh "$folded" 2>/dev/null | cut -f1 || echo "N/A")"
      log_info "folded=${folded_size}, deleting raw perf.data"
      rm -f "$perf_data"
   else
      log_info "fold failed, keeping raw perf.data"
   fi
}

# -----------------------------------------------------------------------------
# Run one perf_record experiment
# -----------------------------------------------------------------------------
run_perf_record_ycsb() {
   local wl="$1" mode="$2" theta="$3"

   local build_dir binary result_file perf_data warmup start_ts exit_code=0 elapsed data_size
   build_dir="$(get_build_dir "$mode")"
   binary="$build_dir/experiment_1_ycsb_${wl}"
   result_file="$RESULT_DIR/perf_record_ycsb_${wl}_${mode}_theta${theta}.log"
   perf_data="$FLAMEGRAPH_DIR/perf_ycsb_${wl}_${mode}_theta${theta}.data"

   if [[ ! -x "$binary" ]]; then
      echo "[ERROR] binary not found: $binary"
      return 1
   fi

   warmup="$WARMUP_LOOKUPS_TIER1"
   is_tier2_warmup "$wl" && warmup="$WARMUP_LOOKUPS_TIER2"

   build_mode_flags "$mode" "$wl"
   rm -f "$SSD_PATH"

   log_info "PERF_RECORD ycsb_${wl} mode=${mode} theta=${theta}"

   start_ts=$(date +%s)
   perf record -g -F "$PERF_RECORD_FREQ" -o "$perf_data" -- \
      "$binary" \
         --test_zipf_theta="$theta" \
         --test_working_set_gib="$WS_GIB" \
         --test_payload_size_bytes="$PAYLOAD_SIZE_BYTES" \
         --test_warmup_lookups="$warmup" \
         --test_measure_lookups="$RECORD_MEASURE_LOOKUPS" \
         --test_progress_interval="$PROGRESS_INTERVAL" \
         --test_warmup_progress_interval="$WARMUP_PROGRESS_INTERVAL" \
         --worker_threads="$WORKER_THREADS" \
         --vi=true --wal=true --trunc=true \
         --ssd_path="$SSD_PATH" \
         "${MODE_FLAGS[@]}" \
         2>&1 | tee "$result_file" || exit_code=$?

   elapsed=$(( $(date +%s) - start_ts ))
   data_size="$(du -sh "$perf_data" 2>/dev/null | cut -f1 || echo "N/A")"

   if [[ "$exit_code" -ne 0 ]]; then
      log_info "[FAIL] record ycsb_${wl} mode=${mode} exit=$exit_code (${elapsed}s)"
   else
      log_info "[PASS] record ycsb_${wl} mode=${mode} (${elapsed}s, perf.data=${data_size})"
   fi
   echo "[TIME] record ycsb_${wl} ${mode} elapsed=${elapsed}s perf.data=${data_size}" | tee -a "$result_file"

   # Fold perf.data immediately and delete raw file to save disk space
   fold_perf_data "$perf_data"

   sleep "$COOLDOWN_SECONDS"
}

# =============================================================================
# Main: run the 9 missing experiments
# =============================================================================
PASS_COUNT=0
FAIL_COUNT=0
OVERALL_START=$(date +%s)

echo "" | tee -a "$MASTER_LOG"
echo "========================================" | tee -a "$MASTER_LOG"
echo "  Resume: 9 missing perf_record experiments" | tee -a "$MASTER_LOG"
echo "  Run dir: $RESULT_DIR" | tee -a "$MASTER_LOG"
echo "  DAX: $CXL_DAX_DEVICE  SSD: $SSD_PATH" | tee -a "$MASTER_LOG"
echo "  perf.data → $FLAMEGRAPH_DIR (auto-folded)" | tee -a "$MASTER_LOG"
echo "========================================" | tee -a "$MASTER_LOG"

# Pre-flight
if [[ ! -e "$CXL_DAX_DEVICE" ]]; then
   echo "[ERROR] $CXL_DAX_DEVICE not found" | tee -a "$MASTER_LOG"
   exit 1
fi
if command -v lsof >/dev/null 2>&1; then
   stale="$(lsof -t "$CXL_DAX_DEVICE" 2>/dev/null || true)"
   if [[ -n "$stale" ]]; then
      echo "[ERROR] $CXL_DAX_DEVICE busy (pids: $stale)" | tee -a "$MASTER_LOG"
      exit 1
   fi
fi
log_info "Pre-flight OK."

# --- ycsb_f: 4 missing modes ---
for mode in two_level_wt bf-tree tiered-indexing-zxj hybried-tier-asplos2025; do
   if run_perf_record_ycsb "f" "$mode" "$RECORD_THETA"; then
      PASS_COUNT=$((PASS_COUNT + 1))
   else
      FAIL_COUNT=$((FAIL_COUNT + 1))
   fi
done

# --- ycsb_e: all 5 modes ---
for mode in "${MODES[@]}"; do
   if run_perf_record_ycsb "e" "$mode" "$RECORD_THETA"; then
      PASS_COUNT=$((PASS_COUNT + 1))
   else
      FAIL_COUNT=$((FAIL_COUNT + 1))
   fi
done

# --- Summary ---
OVERALL_SEC=$(( $(date +%s) - OVERALL_START ))
OVERALL_HR=$(awk "BEGIN {printf \"%.2f\", $OVERALL_SEC / 3600.0}")

echo "" | tee -a "$MASTER_LOG"
echo "========================================" | tee -a "$MASTER_LOG"
echo "  RESUME COMPLETE" | tee -a "$MASTER_LOG"
echo "  $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$MASTER_LOG"
echo "========================================" | tee -a "$MASTER_LOG"
log_info "wall-clock = ${OVERALL_SEC}s (${OVERALL_HR} hr)"
log_info "pass=${PASS_COUNT} fail=${FAIL_COUNT} / 9"
log_info "Results in: $RESULT_DIR"
log_info "Folded stacks: $FOLDED_DIR"
log_info "Perf reports: $PERF_REPORT_DIR"
