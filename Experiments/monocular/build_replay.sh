#!/bin/bash
# Compile the production provider against synthetic frame fields, without an iOS ARSession.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-build/monocular}"
mkdir -p "$out"
swift build --package-path Packages/SpatialCore -c release
bin=$(swift build --package-path Packages/SpatialCore -c release --show-bin-path)
if [[ -f "$bin/libSpatialCore.a" ]]; then
    link=(-I "$bin" "$bin/libSpatialCore.a")
else
    link=(-I "$bin/Modules" "$bin/SpatialCore.build/"*.swift.o)
fi
# Remove only this platform import; do not copy/reimplement prediction or sampling in the fixture.
sed '/^import ARKit$/d' PRTS/Spatial/Depth/MonocularDepthProvider.swift > "$out/MonocularDepthProvider.swift"
xcrun swiftc -O "${link[@]}" PRTS/Spatial/Depth/CoreMLDepthModel.swift "$out/MonocularDepthProvider.swift" \
    Experiments/monocular/FusionReplay.swift -o "$out/fusion-replay"
xcrun coremlcompiler compile PRTS/Spatial/Models/DepthAnythingV2SmallF16.mlpackage "$out"
