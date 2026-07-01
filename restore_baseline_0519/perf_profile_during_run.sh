#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# Perf Profiling Script — attach to experiment processes as they appear
#
# Logic: poll every 2s for any experiment_1_ycsb_* process. When one appears,
# immediately attach perf record + perf stat until it exits, then generate
# flamegraph. Keeps scanning until no new process appears for IDLE_TIMEOUT.
# =============================================================================

FLAMEGRAPH_DIR="/path/to/project/FlameGraph"
RESULT_BASE="/path/to/project/cxl-recordcache-dev/restore_baseline_0519"
PERF_DIR="$RESULT_BASE/perf_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$PERF_DIR"

BINARY_PREFIX="experiment_1_ycsb"
IDLE_TIMEOUT=120  # stop scanning after 2 min with no new process
PERF_FREQ=999

declare -A PROFILED_PIDS=()

echo "============================================================"
echo "  Perf Profiling — auto-attach mode"
echo "============================================================"
echo "[INFO] perf_dir       = $PERF_DIR"
echo "[INFO] frequency      = $PERF_FREQ Hz"
echo "[INFO] idle_timeout   = ${IDLE_TIMEOUT}s"
echo ""

detect_workload_name() {
   local cmdline="$1"
   if [[ "$cmdline" =~ experiment_1_ycsb_([a-z]) ]]; then
      echo "${BASH_REMATCH[1]}"
   else
      echo "unknown"
   fi
}

profile_workload() {
   local pid="$1" wl="$2"
   local prefix="$PERF_DIR/ycsb_${wl}_two_level"

   echo ""
   echo "------------------------------------------------------------"
   echo "[PROFILE] YCSB-${wl^^} (PID=$pid)"
   echo "------------------------------------------------------------"

   if ! kill -0 "$pid" 2>/dev/null; then
      echo "[SKIP] Process $pid already exited"
      return 0
   fi

   perf stat -e cycles,instructions,cache-references,cache-misses,LLC-loads,LLC-load-misses,branch-misses,dTLB-load-misses,page-faults \
      -p "$pid" 2>"${prefix}.perf_stat" &
   local stat_pid=$!

   perf record -g -F "$PERF_FREQ" --call-graph dwarf,16384 \
      -p "$pid" -o "${prefix}.perf.data" 2>/dev/null &
   local record_pid=$!

   echo "[ATTACHED] perf record (PID=$record_pid) + perf stat (PID=$stat_pid)"
   echo "[WAIT] Waiting for YCSB-${wl^^} to finish..."

   while kill -0 "$pid" 2>/dev/null; do
      sleep 5
   done
   echo "[DONE] YCSB-${wl^^} exited"

   sleep 2
   kill "$stat_pid" 2>/dev/null || true
   kill "$record_pid" 2>/dev/null || true
   wait "$stat_pid" 2>/dev/null || true
   wait "$record_pid" 2>/dev/null || true

   echo "[STAT] → ${prefix}.perf_stat"

   # Flamegraph
   if [[ -f "${prefix}.perf.data" ]] && [[ -s "${prefix}.perf.data" ]]; then
      echo "[FLAME] Generating flamegraph..."
      perf script -i "${prefix}.perf.data" 2>/dev/null | \
         "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" --all > "${prefix}.folded" 2>/dev/null || true

      if [[ -s "${prefix}.folded" ]]; then
         "$FLAMEGRAPH_DIR/flamegraph.pl" \
            --title "YCSB-${wl^^} two_level (ws=4G theta=0.90)" \
            --width 1800 \
            "${prefix}.folded" > "${prefix}.svg" 2>/dev/null || true
         echo "[FLAME] → ${prefix}.svg"
      fi

      perf report -i "${prefix}.perf.data" --stdio --no-children \
         -s symbol --percent-limit 0.5 2>/dev/null | head -80 > "${prefix}.top_functions.txt" || true
      echo "[REPORT] → ${prefix}.top_functions.txt"
   else
      echo "[WARN] No perf data captured (process too short?)"
   fi

   echo "[PROFILE] YCSB-${wl^^} complete"
}

# =============================================================================
# Main loop: scan for new experiment processes
# =============================================================================
idle_count=0

echo "[SCAN] Watching for ${BINARY_PREFIX}_* processes..."
echo ""

while true; do
   found_new=false

   for pid in $(pgrep -f "$BINARY_PREFIX" 2>/dev/null || true); do
      if [[ -n "${PROFILED_PIDS[$pid]:-}" ]]; then
         continue
      fi

      if ! kill -0 "$pid" 2>/dev/null; then
         continue
      fi

      cmdline=$(cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ' || true)
      wl=$(detect_workload_name "$cmdline")

      PROFILED_PIDS[$pid]=1
      found_new=true
      idle_count=0

      profile_workload "$pid" "$wl"
   done

   if [[ "$found_new" == "false" ]]; then
      idle_count=$((idle_count + 2))
      if [[ $idle_count -ge $IDLE_TIMEOUT ]]; then
         echo ""
         echo "[EXIT] No new process for ${IDLE_TIMEOUT}s, done."
         break
      fi
   fi

   sleep 2
done

echo ""
echo "============================================================"
echo "  All profiling complete"
echo "============================================================"
echo "[RESULTS] $PERF_DIR"
echo ""
ls -lh "$PERF_DIR"/*.svg 2>/dev/null || echo "(no SVGs)"
ls -lh "$PERF_DIR"/*.perf.data 2>/dev/null || echo "(no perf data)"
