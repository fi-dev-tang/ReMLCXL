#!/usr/bin/env bash
set -euo pipefail
trap '' HUP

# =============================================================================
# Rerun: ycsb_d two_level_readonly theta=0.95  (exp7 Group1 failed test)
#
# DAX = dax0.6,  SSD = exp7_comparison_ssd
# Result saved to original exp7 group1 result dir (overwrite old log)
# =============================================================================

BINARY="/path/to/project/ReMLCXL-ReadOnly/build/frontend/experiment_1_ycsb_d"
SSD_PATH="/path/to/data/cxl_test_tmp/exp7_comparison_ssd"
CXL_DAX_DEVICE="/dev/dax0.6"

RESULT_DIR="/path/to/project/ReMLCXL_experiments/exp7_scripts/run_ycsb_d_rerun"
mkdir -p "$RESULT_DIR"
RESULT_FILE="$RESULT_DIR/ycsb_d_two_level_readonly_theta0.95.log"

echo "============================================================"
echo "  Rerun: ycsb_d two_level_readonly theta=0.95"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

rm -f "$SSD_PATH"

START_TS=$(date +%s)

"$BINARY" \
    --test_zipf_theta=0.95 \
    --test_working_set_gib=23.0 \
    --test_payload_size_bytes=100 \
    --test_warmup_lookups=50000000 \
    --test_measure_lookups=200000000 \
    --test_progress_interval=1000000 \
    --test_warmup_progress_interval=2000000 \
    --worker_threads=20 \
    --vi=true --wal=true --trunc=true \
    --ssd_path="$SSD_PATH" \
    --test_admission_mode=two_level \
    --cxl_tiering_enabled=true \
    --cxl_gib=18.0 \
    --cxl_dax_device_path="$CXL_DAX_DEVICE" \
    --pp_threads=1 \
    --cxl_pp_threads=1 \
    --two_level_admission_threads=2 \
    --delay_admission_recordcache_threads_start=true \
    --dram_buffer_pool_gib=0.43 \
    --dram_recordcache_gib=2.57 \
    --forward_epoch_thread=1 \
    --sieve_eviction_thread=1 \
    --record_cache_promote_thread=4 \
    2>&1 | tee "$RESULT_FILE"

EXIT_CODE=${PIPESTATUS[0]}
ELAPSED=$(( $(date +%s) - START_TS ))

echo ""
echo "============================================================"
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo "  [PASS] ycsb_d two_level_readonly theta=0.95"
else
    echo "  [FAIL] ycsb_d two_level_readonly theta=0.95 (exit=$EXIT_CODE)"
fi
echo "  elapsed: ${ELAPSED}s ($(echo "scale=1; $ELAPSED/60" | bc) min)"
echo "  result:  $RESULT_FILE"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
