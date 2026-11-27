#!/bin/bash
# Exercise the real Metal slice without installing an app or loading model weights.
set -euo pipefail
device=${1:?Pass the UDID of a booted arm64 iOS simulator}
here=$(cd "$(dirname "$0")" && pwd)
pkg=$(cd "$here/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

xcrun --sdk iphonesimulator clang++ -std=c++17 -O2 -target arm64-apple-ios17.0-simulator \
    -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -I"$pkg/.build/llama.cpp/ggml/include" "$here/simulator_metal_regression.cpp" \
    "$pkg/PRTSLocalVLM.xcframework/ios-arm64-simulator/libPRTSLocalVLM.a" \
    -framework Foundation -framework Metal -framework Accelerate -o "$out/regression"
codesign -fs - "$out/regression"
xcrun simctl spawn "$device" "$out/regression"
