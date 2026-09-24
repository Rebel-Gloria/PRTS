# PRTS Core Apple integration pin

- Upstream: `https://github.com/Oldcucumber/PRTS_Core.git`
- Branch checked on 2026-09-24: `main` at `0469479b0d6775940b7e50d95b2095fb7d7fedeb`.
- This integration is pinned to that exact commit. Do not move the pin just because upstream `main` advances.
- The front-end baseline was `origin/main` at `c0b0769e1b5cd2eb9afdb1b11197692501b1013b`.
- A fresh `git ls-remote` on 2026-09-24 confirmed both refs still matched those hashes. No later backend commits were inspected or imported.

## What is vendored

`Vendor/PRTSCore` is a reviewed local Swift Package snapshot containing the backend's Foundation contracts and tests, selected Apple Swift sources, the BGRA camera adapter, and small event cue WAVs. The package compiles a lightweight `PRTSAppleModels` target when `Artifacts/prts_vlm.xcframework` is absent. The full upstream Apple target is selected only when that artifact exists and therefore also pulls its pinned sherpa-onnx/ONNX Runtime packages.

No `web/`, Python runtime, test videos, Web speech models, full desktop model weights, or XCFramework binary is copied. The current `PRTSAppleModelsLite` does not pretend to implement `PRTSCoreSession`; its capability report explicitly marks the model session unavailable.

## Refresh procedure

Run `scripts/sync-prts-core.sh` only as an intentional dependency update. It fetches the single hard-coded commit, copies only the selected contracts/Apple sources/tests/docs, never follows the moving `main` branch, and does not copy model binaries. Inspect `git diff` and rerun all checks afterward. To upgrade, first review a candidate SHA, then separately update both this document and the script pin.
