#!/usr/bin/env bash
# Worker: run one track (two_level_readonly OR two_level_wt).
# Invoked by run_breakdown.sh — do not run directly unless debugging.

set -euo pipefail
trap '' HUP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=breakdown_common.sh
source "$SCRIPT_DIR/breakdown_common.sh"

TRACK_MODE="${1:?usage: _run_breakdown_track.sh <two_level_readonly|two_level_wt>}"

: "${RESULT_DIR:?RESULT_DIR not set}"
: "${FLAMEGRAPH_DIR:?FLAMEGRAPH_DIR not set}"
: "${FOLDED_DIR:?FOLDED_DIR not set}"
: "${PERF_REPORT_DIR:?PERF_REPORT_DIR not set}"
: "${CXL_DAX_DEVICE:?CXL_DAX_DEVICE not set}"
: "${SSD_PATH:?SSD_PATH not set}"
: "${TRACK_LOG:?TRACK_LOG not set}"

CURRENT_EXPERIMENT=0
PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()
TRACK_START=$(date +%s)

echo "" | tee -a "$TRACK_LOG"
echo "============================================" | tee -a "$TRACK_LOG"
echo "  Track: ${TRACK_MODE}" | tee -a "$TRACK_LOG"
echo "  DAX=${CXL_DAX_DEVICE}  SSD=${SSD_PATH}" | tee -a "$TRACK_LOG"
echo "  Runs: ${RUNS_PER_TRACK}" | tee -a "$TRACK_LOG"
echo "============================================" | tee -a "$TRACK_LOG"

breakdown_preflight_track "$TRACK_MODE"
breakdown_log_info "Pre-flight OK."

for theta in "${THETAS[@]}"; do
   breakdown_log_phase "Theta = ${theta}"
   for wl in "${WORKLOADS[@]}"; do
      breakdown_run_perf_stat "$wl" "$theta"
      breakdown_run_perf_record "$wl" "$theta"
   done
done

TRACK_SEC=$(( $(date +%s) - TRACK_START ))
TRACK_HR=$(awk "BEGIN {printf \"%.2f\", $TRACK_SEC / 3600.0}")

echo "" | tee -a "$TRACK_LOG"
echo "========================================" | tee -a "$TRACK_LOG"
echo "  TRACK COMPLETE: ${TRACK_MODE}" | tee -a "$TRACK_LOG"
echo "========================================" | tee -a "$TRACK_LOG"
breakdown_log_info "elapsed=${TRACK_SEC}s (${TRACK_HR} hr) pass=${PASS_COUNT} fail=${FAIL_COUNT}"

# Write machine-readable summary for launcher merge
SUMMARY_FILE="$RESULT_DIR/.summary_${TRACK_MODE}"
{
   echo "mode=$TRACK_MODE"
   echo "pass=$PASS_COUNT"
   echo "fail=$FAIL_COUNT"
   echo "elapsed_sec=$TRACK_SEC"
   for t in "${FAILED_TESTS[@]:-}"; do
      [[ -n "$t" ]] && echo "failed=$t"
   done
} > "$SUMMARY_FILE"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
   exit 1
fi
