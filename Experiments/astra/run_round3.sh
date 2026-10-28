#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
diag_root="${1:-/private/tmp/claude-501/-Users-kyf-Documents-PRTS/458323fc-5623-4807-ac7a-fa70db4beaf4/scratchpad/diag/pull-17pm-1028}"
source_root="$(python3 Experiments/astra/round3_sources.py)"
for stage in baseline step1 step2 step3 step4 step5 only1 only2 only3; do
  print "Starting $stage (serial build, -j 2)"
  ASTRA_SOURCE_ROOT="$source_root/$stage" zsh Experiments/astra/run_product.sh "$stage" "$diag_root" > "Experiments/astra/results/round3-$stage.log" 2>&1
  print "Completed $stage"
done
python3 Experiments/astra/report_product.py
