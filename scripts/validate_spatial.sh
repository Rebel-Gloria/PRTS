#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${PRTS_VALIDATION_DIR:-/tmp/PRTS-validation}"
mkdir -p "$output"
swift test --package-path Vendor/SpatialCore --scratch-path "$output/CoreTests"
swift test -c release --package-path Vendor/SpatialCore --scratch-path "$output/CoreRelease"
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore --scratch-path "$output/Contracts"
python3 -m unittest discover -s scripts -p 'test_*.py'
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath "$output/Simulator" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$output/Release" CODE_SIGNING_ALLOWED=NO build
