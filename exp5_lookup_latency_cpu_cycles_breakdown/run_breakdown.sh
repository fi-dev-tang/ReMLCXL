#!/usr/bin/env bash

set -euo pipefail
trap '' HUP

# =============================================================================
# Exp5 — Lookup Latency + CPU Cycle Breakdown (Fig.19 / Fig.20)
#
# Launcher: runs ReadOnly and WriteThrough **in parallel** on separate DAX/SSD.
#
# Matrix (total 72 = 36 per track):
#   RO: two_level_readonly × 6 WL × 3 theta × (stat + record) = 36
#   WT: two_level_wt        × 6 WL × 3 theta × (stat + record) = 36
#
# Default DAX (avoid exp1 on 0.1/0.2 and full exp5 on 0.8):
#   RO → /dev/dax0.3    WT → /dev/dax0.4
# Override: RO_DAX_DEVICE=... WT_DAX_DEVICE=...
#
# Wall-clock ≈ max(RO, WT) ≈ half of serial (~18–25 h vs ~35–50 h).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=breakdown_common.sh
source "$SCRIPT_DIR/breakdown_common.sh"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$SCRIPT_DIR/run_${TIMESTAMP}"
# perf.data files are large (11–20G each); store on /data1 to avoid filling /home
FLAMEGRAPH_DIR="/path/to/data/cxl_test_tmp/exp5_perf_data/${TIMESTAMP}"
FOLDED_DIR="$RESULT_DIR/folded_stacks"
PERF_REPORT_DIR="$RESULT_DIR/perf_reports"
MASTER_LOG="$RESULT_DIR/master.log"

RO_DAX_DEVICE="${RO_DAX_DEVICE:-/dev/dax0.3}"
WT_DAX_DEVICE="${WT_DAX_DEVICE:-/dev/dax0.4}"
RO_SSD_PATH="${RO_SSD_PATH:-/path/to/data/cxl_test_tmp/exp5_latency_cycles_ro}"
WT_SSD_PATH="${WT_SSD_PATH:-/path/to/data/cxl_test_tmp/exp5_latency_cycles_wt}"

RO_TRACK_LOG="$RESULT_DIR/master_ro.log"
WT_TRACK_LOG="$RESULT_DIR/master_wt.log"
TRACK_SCRIPT="$SCRIPT_DIR/_run_breakdown_track.sh"

TOTAL_EXPERIMENTS=$(( RUNS_PER_TRACK * 2 ))
OVERALL_START=$(date +%s)

mkdir -p "$RESULT_DIR" "$FLAMEGRAPH_DIR" "$FOLDED_DIR" "$PERF_REPORT_DIR"

log_master() { echo "$*" | tee -a "$MASTER_LOG"; }

check_dax_free() {
   local dev="$1" label="$2"
   if [[ ! -e "$dev" ]]; then
      log_master "[ERROR] $label: $dev not found"
      return 1
   fi
   if command -v lsof >/dev/null 2>&1; then
      local stale
      stale="$(lsof -t "$dev" 2>/dev/null || true)"
      if [[ -n "$stale" ]]; then
         log_master "[ERROR] $label: $dev busy (pids: $stale)"
         return 1
      fi
   fi
}

preflight_launcher() {
   local ok=0
   check_dax_free "$RO_DAX_DEVICE" "RO" || ok=1
   check_dax_free "$WT_DAX_DEVICE" "WT" || ok=1
   if [[ "$RO_DAX_DEVICE" == "$WT_DAX_DEVICE" ]]; then
      log_master "[ERROR] RO and WT must use different DAX devices"
      ok=1
   fi
   CXL_DAX_DEVICE="$RO_DAX_DEVICE" SSD_PATH="$RO_SSD_PATH"
   breakdown_preflight_track two_level_readonly || ok=1
   CXL_DAX_DEVICE="$WT_DAX_DEVICE" SSD_PATH="$WT_SSD_PATH"
   breakdown_preflight_track two_level_wt || ok=1
   [[ "$ok" -eq 0 ]]
}

launch_track() {
   local mode="$1" dax="$2" ssd="$3" logfile="$4"
   (
      export RESULT_DIR FLAMEGRAPH_DIR FOLDED_DIR PERF_REPORT_DIR
      export CXL_DAX_DEVICE="$dax"
      export SSD_PATH="$ssd"
      export TRACK_LOG="$logfile"
      exec bash "$TRACK_SCRIPT" "$mode"
   )
}

# =============================================================================
# Banner
# =============================================================================
log_master ""
log_master "============================================"
log_master "  Breakdown experiment (RO + WT parallel)"
log_master "  WS=${WS_GIB}G  CXL=${CXL_GIB}G  DRAM=${DRAM_TOTAL}G"
log_master "  RO: DAX=${RO_DAX_DEVICE}  SSD=${RO_SSD_PATH}"
log_master "  WT: DAX=${WT_DAX_DEVICE}  SSD=${WT_SSD_PATH}"
log_master "  Thetas: ${THETAS[*]}  Workloads: ${WORKLOADS[*]}"
log_master "  Total runs: ${TOTAL_EXPERIMENTS} (${RUNS_PER_TRACK} per track)"
log_master "  Result dir: ${RESULT_DIR}"
log_master "============================================"

log_master "[INFO] Pre-flight..."
preflight_launcher
log_master "[INFO] Pre-flight OK."

# =============================================================================
# Parallel tracks
# =============================================================================
log_master "[INFO] Starting RO track (background)..."
launch_track two_level_readonly "$RO_DAX_DEVICE" "$RO_SSD_PATH" "$RO_TRACK_LOG" &
RO_PID=$!

log_master "[INFO] Starting WT track (background)..."
launch_track two_level_wt "$WT_DAX_DEVICE" "$WT_SSD_PATH" "$WT_TRACK_LOG" &
WT_PID=$!

log_master "[INFO] RO pid=$RO_PID  WT pid=$WT_PID — waiting..."

RO_EXIT=0
WT_EXIT=0
wait "$RO_PID" || RO_EXIT=$?
wait "$WT_PID" || WT_EXIT=$?

# =============================================================================
# Merge summary
# =============================================================================
OVERALL_SEC=$(( $(date +%s) - OVERALL_START ))
OVERALL_HR=$(awk "BEGIN {printf \"%.2f\", $OVERALL_SEC / 3600.0}")

TOTAL_PASS=0
TOTAL_FAIL=0

log_master ""
log_master "========================================"
log_master "  BREAKDOWN EXPERIMENT COMPLETE"
log_master "  $(date '+%Y-%m-%d %H:%M:%S')"
log_master "========================================"
log_master "[INFO] wall-clock = ${OVERALL_SEC}s (${OVERALL_HR} hr)"
log_master "[INFO] RO track exit=$RO_EXIT  WT track exit=$WT_EXIT"

for summary in "$RESULT_DIR"/.summary_*; do
   [[ -f "$summary" ]] || continue
   log_master "--- $(basename "$summary") ---"
   while IFS= read -r line; do
      log_master "  $line"
      case "$line" in
         pass=*) TOTAL_PASS=$(( TOTAL_PASS + ${line#pass=} )) ;;
         fail=*) TOTAL_FAIL=$(( TOTAL_FAIL + ${line#fail=} )) ;;
      esac
   done < "$summary"
done

log_master "[INFO] aggregate pass=${TOTAL_PASS} fail=${TOTAL_FAIL} / ${TOTAL_EXPERIMENTS}"
log_master "Logs: master_ro.log, master_wt.log"
log_master ""
log_master "Post-process:"
log_master "  bash extract_latency_metrics.sh ${RESULT_DIR}"
log_master "  perf.data folded inline → ${FOLDED_DIR}, reports → ${PERF_REPORT_DIR}"
log_master "  raw perf.data on /data1: ${FLAMEGRAPH_DIR} (auto-cleaned after folding)"

if [[ "$RO_EXIT" -ne 0 || "$WT_EXIT" -ne 0 || "$TOTAL_FAIL" -gt 0 ]]; then
   exit 1
fi
