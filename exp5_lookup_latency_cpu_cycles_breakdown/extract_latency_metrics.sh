#!/usr/bin/env bash
# Extract grep-friendly Final Summary lines from perf_stat logs → CSV for Fig.19 (b/c).
set -euo pipefail

RESULT_DIR="${1:?usage: extract_latency_metrics.sh <run_TIMESTAMP_dir>}"
OUT="$RESULT_DIR/latency_metrics.csv"

if [[ ! -d "$RESULT_DIR" ]]; then
   echo "[ERROR] not a directory: $RESULT_DIR" >&2
   exit 1
fi

echo "mode,workload,theta,avg_us,rc_hr_pct,cxl_hr_pct,ssd_miss_pct,dram_hr_pct,mqps,p95_us,p99_us,log_file" > "$OUT"

shopt -s nullglob
for log in "$RESULT_DIR"/perf_stat_ycsb_*_theta*.log; do
   base="$(basename "$log" .log)"
   # perf_stat_ycsb_<wl>_<mode>_theta<theta>
   if [[ "$base" =~ perf_stat_ycsb_([a-z])_([^_]+(?:_[^_]+)*)_theta([0-9.]+) ]]; then
      wl="${BASH_REMATCH[1]}"
      mode="${BASH_REMATCH[2]}"
      theta="${BASH_REMATCH[3]}"
   else
      echo "[WARN] skip unrecognized name: $base" >&2
      continue
   fi

   line="$(grep -E 'mode=.*avg_us=.*RC_HR=' "$log" | tail -1 || true)"
   if [[ -z "$line" ]]; then
      echo "[WARN] no summary line in $log" >&2
      continue
   fi

   extract() { echo "$line" | grep -oP "(?<=$1)[0-9.]+" | head -1 || echo ""; }

   avg_us="$(extract 'avg_us=')"
   rc_hr="$(extract 'RC_HR=')"
   cxl_hr="$(extract 'CXL_HR=')"
   ssd="$(extract 'SSD_miss=')"
   dram_hr="$(extract 'DRAM_HR=')"
   mqps="$(extract 'Mqps=')"
   p95="$(extract 'p95_us=')"
   p99="$(extract 'p99_us=')"

   echo "${mode},${wl},${theta},${avg_us},${rc_hr},${cxl_hr},${ssd},${dram_hr},${mqps},${p95},${p99},$(basename "$log")" >> "$OUT"
done

echo "[OK] wrote $OUT ($(tail -n +2 "$OUT" | wc -l) rows)"
