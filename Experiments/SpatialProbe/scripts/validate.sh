#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swift test --package-path Core --scratch-path build/CoreTests 2>&1 | tee build/core-tests.log
swift test -c release --package-path Core --scratch-path build/CoreRelease 2>&1 | tee build/core-release-tests.log
python3 -m unittest discover -s scripts -p 'test_*.py' -v 2>&1 | tee build/report-tests.log
xcodebuild -project PRTSSpatialProbe.xcodeproj -scheme PRTSSpatialProbe \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/device-build.log
xcodebuild -project PRTSSpatialProbe.xcodeproj -scheme PRTSSpatialProbe \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/Release CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/device-release-build.log
xcodebuild -project PRTSSpatialProbe.xcodeproj -scheme PRTSSpatialProbe \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Simulator CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/simulator-build.log
