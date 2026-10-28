#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
diag_root="${1:-/private/tmp/claude-501/-Users-kyf-Documents-PRTS/458323fc-5623-4807-ac7a-fa70db4beaf4/scratchpad/diag/pull-17pm-1028}"
mkdir -p Experiments/astra/{results,bin,generated}
export CLANG_MODULE_CACHE_PATH="$PWD/Experiments/astra/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
python3 Experiments/astra/prepare.py "$diag_root" > Experiments/astra/results/inventory.log
swift build --disable-sandbox --package-path Vendor/SpatialCore --scratch-path Experiments/astra/build -j 2 > Experiments/astra/results/build.log 2>&1
swiftc -O -g -j 2 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I Experiments/astra/build/out/Products/Debug -L Experiments/astra/build/out/Products/Debug -lSpatialCore -o Experiments/astra/bin/replay Experiments/astra/Replay.swift Experiments/astra/Drawing.swift Experiments/astra/generated/*.swift > Experiments/astra/results/tool-build.log 2>&1
Experiments/astra/bin/replay --self-test > Experiments/astra/results/self-tests.log
replay_run="$(python3 -c 'import json; print(json.load(open("Experiments/astra/results/inventory.json"))["run"])')"
Experiments/astra/bin/replay "$replay_run" Experiments/astra/results/index.jsonl > Experiments/astra/results/replay.jsonl 2> Experiments/astra/results/replay.log
python3 Experiments/astra/tests.py > Experiments/astra/results/metric-tests.log 2>&1
python3 Experiments/astra/metrics.py Experiments/astra/results/replay.jsonl > Experiments/astra/results/metrics.log
python3 Experiments/astra/audit.py > Experiments/astra/results/audit.log
python3 Experiments/astra/annotation.py --extract > Experiments/astra/results/annotation.log
swift test --disable-sandbox --package-path Vendor/SpatialCore --scratch-path Experiments/astra/build -j 2 --filter 'PathPredictionTests|RouteProjectionTests|WaypointStabilityTests|OccupancyFootprintTests' > Experiments/astra/results/core-tests.log 2>&1
python3 Experiments/astra/report.py
