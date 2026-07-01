#!/usr/bin/env bash
# Collapse perf_record .data files for Fig.20 cycle breakdown analysis.
set -euo pipefail

RESULT_DIR="${1:?usage: postprocess_perf_records.sh <run_TIMESTAMP_dir>}"
FLAMEGRAPH_TOOL_DIR="${FLAMEGRAPH_TOOL_DIR:-/path/to/project/FlameGraph}"
# If FLAMEGRAPH_DIR is set (perf.data dir from run_breakdown.sh), use it;
# otherwise fall back to the old default inside RESULT_DIR.
DATA_DIR="${FLAMEGRAPH_DIR:-$RESULT_DIR/flamegraph_data}"
OUT_DIR="$RESULT_DIR/folded_stacks"
REPORT_DIR="$RESULT_DIR/perf_reports"

if [[ ! -d "$DATA_DIR" ]]; then
   echo "[ERROR] missing $DATA_DIR" >&2
   exit 1
fi
if [[ ! -x "$FLAMEGRAPH_TOOL_DIR/stackcollapse-perf.pl" ]]; then
   echo "[ERROR] stackcollapse-perf.pl not found at $FLAMEGRAPH_TOOL_DIR" >&2
   exit 1
fi

mkdir -p "$OUT_DIR" "$REPORT_DIR"

shopt -s nullglob
for data in "$DATA_DIR"/perf_ycsb_*.data; do
   base="$(basename "$data" .data)"
   folded="$OUT_DIR/${base}.folded"
   report="$REPORT_DIR/${base}.txt"

   echo "[INFO] folding $base"
   perf script -i "$data" 2>/dev/null \
      | "$FLAMEGRAPH_TOOL_DIR/stackcollapse-perf.pl" --all > "$folded" || {
         echo "[WARN] stackcollapse failed for $base" >&2
         continue
      }

   perf report -i "$data" --stdio --no-children --sort comm,dso,symbol 2>/dev/null \
      | head -80 > "$report" || true
done

echo "[OK] folded stacks in $OUT_DIR"
echo "[OK] perf report snippets in $REPORT_DIR"
echo ""
echo "Next: classify folded stacks into sieve/mutex/admit/promote/gcommit/other"
echo "      (see plot_wt_cycle_breakdown_0610_rerun.py for category rules)"
