#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
diag_root="${1:?Pass the diagnostic capture directory}"
source_root="$(python3 Experiments/astra/round3_sources.py)"
for stage in baseline step1 step2 step3 step4 step5 only1 only2 only3; do
    printf "%s\n" "Starting $stage (serial build, -j 2)"
    ASTRA_SOURCE_ROOT="$source_root/$stage" bash Experiments/astra/run_product.sh "$stage" "$diag_root" > "Experiments/astra/results/round3-$stage.log" 2>&1
    printf "%s\n" "Completed $stage"
done
python3 Experiments/astra/report_product.py
