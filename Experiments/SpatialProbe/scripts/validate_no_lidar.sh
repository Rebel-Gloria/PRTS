#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/NoLiDAR
python3 scripts/verify_coreml_model.py
bash scripts/validate.sh
bin=$(swift build --package-path Core --scratch-path build/CoreTests --show-bin-path)
swiftc -I "$bin/Modules" "$bin/SpatialCore.build/"*.swift.o App/CoreMLDepthModel.swift scripts/smoke_coreml.swift -o build/NoLiDAR/smoke_coreml
build/NoLiDAR/smoke_coreml App/Models/DepthAnythingV2SmallF16.mlpackage > build/NoLiDAR/model-runtime-smoke.json
