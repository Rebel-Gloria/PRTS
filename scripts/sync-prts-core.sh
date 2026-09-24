#!/usr/bin/env bash
set -euo pipefail

# Intentional pin: only update this together with a reviewed integration change.
readonly upstream='https://github.com/Oldcucumber/PRTS_Core.git'
readonly revision='0469479b0d6775940b7e50d95b2095fb7d7fedeb'
readonly root="$(cd "$(dirname "$0")/.." && pwd)"
readonly temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT

git -C "$temp" init -q
git -C "$temp" remote add origin "$upstream"
git -C "$temp" fetch --depth=1 origin "$revision"
test "$(git -C "$temp" rev-parse FETCH_HEAD)" = "$revision"
git -C "$temp" checkout -q --detach "$revision"

mkdir -p "$root/Vendor/PRTSCore/Sources/PRTSContracts" \
  "$root/Vendor/PRTSCore/Sources/PRTSAppleModels" \
  "$root/Vendor/PRTSCore/Tests/PRTSContractsTests/Resources" \
  "$root/docs"
cp "$temp/apple/PRTSCore/Sources/PRTSContracts/"*.swift "$root/Vendor/PRTSCore/Sources/PRTSContracts/"
cp "$temp/apple/PRTSCore/Sources/PRTSAppleModels/"*.swift "$root/Vendor/PRTSCore/Sources/PRTSAppleModels/"
mkdir -p "$root/Vendor/PRTSCore/Sources/PRTSAppleModels/Resources/cues"
cp "$temp/apple/PRTSCore/Sources/PRTSAppleModels/Resources/cues/"* "$root/Vendor/PRTSCore/Sources/PRTSAppleModels/Resources/cues/"
cp "$temp/apple/PRTSCore/Tests/PRTSContractsTests/"*.swift "$root/Vendor/PRTSCore/Tests/PRTSContractsTests/"
cp "$temp/apple/PRTSCore/Tests/PRTSContractsTests/Resources/python-parity.json" \
  "$root/Vendor/PRTSCore/Tests/PRTSContractsTests/Resources/"
cp "$temp/docs/INTERFACE_SPEC.md" "$root/docs/PRTS_CORE_INTERFACE_SPEC.md"
cp "$temp/docs/APPLE_INTEGRATION.md" "$root/docs/PRTS_CORE_APPLE_INTEGRATION.md"
cp "$temp/apple/README.md" "$root/docs/PRTS_CORE_APPLE_README.md"

printf 'Synchronized selected Apple files from %s at %s.\n' "$upstream" "$revision"
printf 'Models/XCFrameworks were deliberately not copied. Review diff before committing.\n'
