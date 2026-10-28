#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
diag_root="${1:-/private/tmp/claude-501/-Users-kyf-Documents-PRTS/458323fc-5623-4807-ac7a-fa70db4beaf4/scratchpad/diag/pull-17pm-1028}"
mkdir -p experiments/astra/{results,bin,generated}
export CLANG_MODULE_CACHE_PATH="$PWD/experiments/astra/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
python3 experiments/astra/prepare.py "$diag_root" > experiments/astra/results/inventory.log
swift build --disable-sandbox --package-path Vendor/SpatialCore --scratch-path experiments/astra/build -j 2 > experiments/astra/results/build.log 2>&1
swiftc -O -g -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I experiments/astra/build/out/Products/Debug -L experiments/astra/build/out/Products/Debug -lSpatialCore -o experiments/astra/bin/replay experiments/astra/Replay.swift experiments/astra/Drawing.swift experiments/astra/generated/*.swift > experiments/astra/results/tool-build.log 2>&1
experiments/astra/bin/replay --self-test > experiments/astra/results/self-tests.log
replay_run="$(python3 -c 'import json; print(json.load(open("experiments/astra/results/inventory.json"))["run"])')"
experiments/astra/bin/replay "$replay_run" experiments/astra/results/index.jsonl > experiments/astra/results/replay.jsonl 2> experiments/astra/results/replay.log
python3 experiments/astra/tests.py > experiments/astra/results/metric-tests.log 2>&1
python3 experiments/astra/metrics.py experiments/astra/results/replay.jsonl > experiments/astra/results/metrics.log
python3 experiments/astra/audit.py > experiments/astra/results/audit.log
python3 experiments/astra/annotation.py --extract > experiments/astra/results/annotation.log
swift test --disable-sandbox --package-path Vendor/SpatialCore --scratch-path experiments/astra/build -j 2 --filter 'PathPredictionTests|RouteProjectionTests|WaypointStabilityTests|OccupancyFootprintTests' > experiments/astra/results/core-tests.log 2>&1
python3 experiments/astra/report.py
