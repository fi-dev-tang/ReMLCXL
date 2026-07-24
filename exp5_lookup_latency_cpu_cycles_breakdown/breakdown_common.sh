#!/usr/bin/env bash
# Shared config and helpers for lookup latency / CPU cycle breakdown experiments.
# Sourced by run_breakdown.sh (launcher) and _run_breakdown_track.sh (worker).

# Repos
BUILD_DIR_RO="/path/to/project/CellarCXL-ReadOnly/build/frontend"
BUILD_DIR_WT="/path/to/project/CellarCXL-WriteThrough/build/frontend"

# Tier / benchmark (exp7 comparison config)
WS_GIB=23.0
CXL_GIB=18.0
DRAM_TOTAL=3.0
TWO_LEVEL_BP_ABCF=0.43
TWO_LEVEL_RC_ABCF=2.57
TWO_LEVEL_BP_DE=2.57
TWO_LEVEL_RC_DE=0.43

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

WARMUP_TIER1=800000000
WARMUP_TIER2=50000000
STAT_MEASURE=200000000
RECORD_MEASURE=50000000

THETAS=(0.90 0.95 0.99)
WORKLOADS=(b c a d f e)

PERF_STAT_EVENTS="cycles,instructions,cache-references,cache-misses,branches,branch-misses,context-switches,cpu-migrations,page-faults,bus-cycles"
PERF_RECORD_FREQ=99
FLAMEGRAPH_TOOL_DIR="/path/to/project/FlameGraph"

# Per-track experiment count: 6 wl × 3 theta × 2 phases
RUNS_PER_TRACK=$(( ${#WORKLOADS[@]} * ${#THETAS[@]} * 2 ))

breakdown_get_build_dir() {
   case "$1" in
      two_level_readonly) echo "$BUILD_DIR_RO" ;;
      two_level_wt)       echo "$BUILD_DIR_WT" ;;
      *) echo "[ERROR] unknown mode: $1" >&2; return 1 ;;
   esac
}

breakdown_get_admission_mode() {
   case "$1" in
      two_level_readonly|two_level_wt) echo "two_level" ;;
   esac
}

breakdown_is_tier2_warmup() {
   case "$1" in d|e) return 0 ;; *) return 1 ;; esac
}

breakdown_is_tier2_bp_rc() {
   case "$1" in e) return 0 ;; *) return 1 ;; esac
}

breakdown_get_theta_tuning_flags() {
   case "$1" in
      0.90)
         cat <<'EOF'
--skew_threshold_ratio=0.08
--uniform_threshold_ratio=0.45
--max_per_page_visits=8000
--max_global_requests_window=2000000
--trigger_visit_histogram_update_size=1000000
EOF
         ;;
   esac
}

# Requires: TRACK_MODE, CXL_DAX_DEVICE, SSD_PATH, BUILD_DIR (set by caller)
breakdown_preflight_track() {
   local mode="$1"
   if [[ ! -e "$CXL_DAX_DEVICE" ]]; then
      echo "[ERROR] [$mode] dax device $CXL_DAX_DEVICE not found" >&2
      return 1
   fi
   if command -v lsof >/dev/null 2>&1; then
      local stale
      stale="$(lsof -t "$CXL_DAX_DEVICE" 2>/dev/null || true)"
      if [[ -n "$stale" ]]; then
         echo "[ERROR] [$mode] dax device $CXL_DAX_DEVICE busy (pids: $stale)" >&2
         return 1
      fi
   fi
   local build_dir
   build_dir="$(breakdown_get_build_dir "$mode")"
   local wl
   for wl in "${WORKLOADS[@]}"; do
      if [[ ! -x "$build_dir/experiment_1_ycsb_${wl}" ]]; then
         echo "[ERROR] [$mode] binary not found: $build_dir/experiment_1_ycsb_${wl}" >&2
         return 1
      fi
   done
}

# Requires: TRACK_MODE, RESULT_DIR, FLAMEGRAPH_DIR, TRACK_LOG, CXL_DAX_DEVICE, SSD_PATH
#           PASS_COUNT, FAIL_COUNT, FAILED_TESTS (namerefs or global arrays in worker)
breakdown_build_mode_flags() {
   local wl="$1" theta="$2"
   local admission_mode
   admission_mode="$(breakdown_get_admission_mode "$TRACK_MODE")"

   local bp_gib rc_gib
   if breakdown_is_tier2_bp_rc "$wl"; then
      bp_gib="$TWO_LEVEL_BP_DE"
      rc_gib="$TWO_LEVEL_RC_DE"
   else
      bp_gib="$TWO_LEVEL_BP_ABCF"
      rc_gib="$TWO_LEVEL_RC_ABCF"
   fi

   local theta_flags=()
   local line
   while IFS= read -r line; do
      [[ -n "$line" ]] && theta_flags+=("$line")
   done < <(breakdown_get_theta_tuning_flags "$theta")

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
      "${theta_flags[@]}"
   )
}

breakdown_log_info()  { echo "[INFO] [${TRACK_MODE}] $(date +%H:%M:%S) $*" | tee -a "$TRACK_LOG"; }
breakdown_log_phase() {
   echo "" | tee -a "$TRACK_LOG"
   echo "========================================" | tee -a "$TRACK_LOG"
   echo "  [$TRACK_MODE] $*" | tee -a "$TRACK_LOG"
   echo "========================================" | tee -a "$TRACK_LOG"
   echo "" | tee -a "$TRACK_LOG"
}
breakdown_log_pass()  { echo "[PASS] [${TRACK_MODE}] $*" | tee -a "$TRACK_LOG"; }
breakdown_log_fail()  { echo "[FAIL] [${TRACK_MODE}] $*" | tee -a "$TRACK_LOG"; }

# Fold perf.data → .folded text + perf report snippet, then delete raw perf.data.
# Called after each perf_record run to prevent disk accumulation.
breakdown_fold_perf_data() {
   local perf_data="$1"
   local base folded report flamegraph_tool

   base="$(basename "$perf_data" .data)"
   folded="$FOLDED_DIR/${base}.folded"
   report="$PERF_REPORT_DIR/${base}.txt"
   flamegraph_tool="$FLAMEGRAPH_TOOL_DIR/stackcollapse-perf.pl"

   if [[ ! -f "$perf_data" ]] || [[ ! -s "$perf_data" ]]; then
      breakdown_log_info "perf.data missing or empty, skipping fold"
      return 0
   fi
   if [[ ! -x "$flamegraph_tool" ]]; then
      breakdown_log_info "stackcollapse-perf.pl not found, keeping raw perf.data"
      return 0
   fi

   breakdown_log_info "folding perf.data → ${base}.folded"
   if perf script -i "$perf_data" 2>/dev/null \
      | "$flamegraph_tool" --all > "$folded" 2>/dev/null; then
      perf report -i "$perf_data" --stdio --no-children --sort comm,dso,symbol 2>/dev/null \
         | head -80 > "$report" || true
      local folded_size
      folded_size="$(du -sh "$folded" 2>/dev/null | cut -f1 || echo "N/A")"
      breakdown_log_info "folded=${folded_size}, deleting raw perf.data"
      rm -f "$perf_data"
   else
      breakdown_log_info "fold failed, keeping raw perf.data"
   fi
}

breakdown_run_perf_stat() {
   local wl="$1" theta="$2"
   CURRENT_EXPERIMENT=$((CURRENT_EXPERIMENT + 1))

   local build_dir binary result_file stat_file warmup start_ts exit_code elapsed
   build_dir="$(breakdown_get_build_dir "$TRACK_MODE")"
   binary="$build_dir/experiment_1_ycsb_${wl}"
   result_file="$RESULT_DIR/perf_stat_ycsb_${wl}_${TRACK_MODE}_theta${theta}.log"
   stat_file="$RESULT_DIR/perf_stat_ycsb_${wl}_${TRACK_MODE}_theta${theta}.perf_stat"

   if [[ ! -x "$binary" ]]; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("perf_stat_ycsb_${wl}_${TRACK_MODE}_theta${theta}:MISSING_BINARY")
      return 0
   fi

   warmup="$WARMUP_TIER1"
   breakdown_is_tier2_warmup "$wl" && warmup="$WARMUP_TIER2"

   breakdown_build_mode_flags "$wl" "$theta"
   rm -f "$SSD_PATH"

   breakdown_log_info "[$CURRENT_EXPERIMENT/$RUNS_PER_TRACK] PERF_STAT ycsb_${wl} theta=${theta}"

   start_ts=$(date +%s)
   exit_code=0
   perf stat -e "$PERF_STAT_EVENTS" -o "$stat_file" -- \
      "$binary" \
         --test_zipf_theta="$theta" \
         --test_working_set_gib="$WS_GIB" \
         --test_payload_size_bytes="$PAYLOAD_SIZE_BYTES" \
         --test_warmup_lookups="$warmup" \
         --test_measure_lookups="$STAT_MEASURE" \
         --test_progress_interval="$PROGRESS_INTERVAL" \
         --test_warmup_progress_interval="$WARMUP_PROGRESS_INTERVAL" \
         --worker_threads="$WORKER_THREADS" \
         --vi=true --wal=true --trunc=true \
         --ssd_path="$SSD_PATH" \
         "${MODE_FLAGS[@]}" \
         2>&1 | tee "$result_file" || exit_code=$?

   elapsed=$(( $(date +%s) - start_ts ))
   if [[ "$exit_code" -ne 0 ]]; then
      breakdown_log_fail "perf_stat ycsb_${wl} theta=${theta} exit=$exit_code (${elapsed}s)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("perf_stat_ycsb_${wl}_${TRACK_MODE}_theta${theta}:exit${exit_code}")
   else
      breakdown_log_pass "perf_stat ycsb_${wl} theta=${theta} (${elapsed}s)"
      PASS_COUNT=$((PASS_COUNT + 1))
   fi
   echo "[TIME] perf_stat ycsb_${wl} ${TRACK_MODE} theta=${theta} elapsed=${elapsed}s" | tee -a "$result_file"
   sleep "$COOLDOWN_SECONDS"
}

breakdown_run_perf_record() {
   local wl="$1" theta="$2"
   CURRENT_EXPERIMENT=$((CURRENT_EXPERIMENT + 1))

   local build_dir binary result_file perf_data warmup start_ts exit_code elapsed data_size
   build_dir="$(breakdown_get_build_dir "$TRACK_MODE")"
   binary="$build_dir/experiment_1_ycsb_${wl}"
   result_file="$RESULT_DIR/perf_record_ycsb_${wl}_${TRACK_MODE}_theta${theta}.log"
   perf_data="$FLAMEGRAPH_DIR/perf_ycsb_${wl}_${TRACK_MODE}_theta${theta}.data"

   if [[ ! -x "$binary" ]]; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("perf_record_ycsb_${wl}_${TRACK_MODE}_theta${theta}:MISSING_BINARY")
      return 0
   fi

   warmup="$WARMUP_TIER1"
   breakdown_is_tier2_warmup "$wl" && warmup="$WARMUP_TIER2"

   breakdown_build_mode_flags "$wl" "$theta"
   rm -f "$SSD_PATH"

   breakdown_log_info "[$CURRENT_EXPERIMENT/$RUNS_PER_TRACK] PERF_RECORD ycsb_${wl} theta=${theta}"

   start_ts=$(date +%s)
   exit_code=0
   perf record -g --call-graph dwarf,16384 -F "$PERF_RECORD_FREQ" -o "$perf_data" -- \
      "$binary" \
         --test_zipf_theta="$theta" \
         --test_working_set_gib="$WS_GIB" \
         --test_payload_size_bytes="$PAYLOAD_SIZE_BYTES" \
         --test_warmup_lookups="$warmup" \
         --test_measure_lookups="$RECORD_MEASURE" \
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
      breakdown_log_fail "perf_record ycsb_${wl} theta=${theta} exit=$exit_code (${elapsed}s)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS+=("perf_record_ycsb_${wl}_${TRACK_MODE}_theta${theta}:exit${exit_code}")
   else
      breakdown_log_pass "perf_record ycsb_${wl} theta=${theta} (${elapsed}s, perf.data=${data_size})"
      PASS_COUNT=$((PASS_COUNT + 1))
   fi
   echo "[TIME] perf_record ycsb_${wl} ${TRACK_MODE} theta=${theta} elapsed=${elapsed}s perf.data=${data_size}" | tee -a "$result_file"

   # Fold perf.data immediately and delete raw file to save disk space
   breakdown_fold_perf_data "$perf_data"

   sleep "$COOLDOWN_SECONDS"
}
