#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
label="${1:?usage: run_product.sh label [diag]}"
diag_root="${2:-/private/tmp/claude-501/-Users-kyf-Documents-PRTS/458323fc-5623-4807-ac7a-fa70db4beaf4/scratchpad/diag/pull-17pm-1028}"
mkdir -p Experiments/astra/{results,bin,generated}
export CLANG_MODULE_CACHE_PATH="$PWD/Experiments/astra/build-product/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
python3 Experiments/astra/prepare_product.py "$diag_root" > Experiments/astra/results/product-inventory.log
swift build --disable-sandbox --package-path Experiments/astra/generated/ProductCore --scratch-path Experiments/astra/build-product -j 2 > Experiments/astra/results/product-build.log 2>&1
swiftc -O -g -j 2 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I Experiments/astra/build-product/out/Products/Debug -L Experiments/astra/build-product/out/Products/Debug -lSpatialCore -o Experiments/astra/bin/replay-product Experiments/astra/ReplayProduct.swift Experiments/astra/generated/ProductSpeech.swift Experiments/astra/generated/ProductTurns.swift Experiments/astra/generated/ProductAdapter.swift > Experiments/astra/results/product-tool-build.log 2>&1
swift test --disable-sandbox --package-path Experiments/astra/generated/ProductCore --scratch-path Experiments/astra/build-product -j 2 > Experiments/astra/results/product-tests.log 2>&1
replay_run="$(python3 -c 'import json; print(json.load(open("Experiments/astra/results/inventory.json"))["run"])')"
Experiments/astra/bin/replay-product "$replay_run" Experiments/astra/results/index.jsonl > Experiments/astra/results/product-replay.jsonl 2> Experiments/astra/results/product-replay.log
python3 Experiments/astra/metrics_product.py
python3 Experiments/astra/seal_product.py
mkdir -p "Experiments/astra/results/round3/$label"
cp Experiments/astra/results/{product-replay.jsonl,product-ticks.jsonl,product_manifest.json,product_metrics.json,product-tests.log,inventory.json,missing_frames.json,recovered_frames.json} "Experiments/astra/results/round3/$label/"
