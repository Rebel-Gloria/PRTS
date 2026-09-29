# Build16 round-1 validation and delivery

See [implementation and remaining work](ROUTE_CONTINUITY_2026-09-29.md).

## Executed checks

| Check | Result |
|---|---|
| Baseline SpatialCore / contracts / Python | 248 / 8 / 45 passed |
| New before-fix regression cases | 3 failed as expected; now passed |
| Final SpatialCore Debug and Release | 270 passed in each configuration (22 new) |
| PRTSCore contracts-only | 8 passed |
| Python readers/replay/source contracts/inventory | 46 passed |
| Ordinary Release iPhoneOS build | Passed, unsigned |
| Dev Debug simulator app tests | 14 passed; not LiDAR verification |
| Signed Dev Release / physical install | Passed; build16 installed and launched on Gloria iPhone 15 Pro |
| New-version sensor/controlled walking/thermal acceptance | Not performed |

One intermediate rolling-tail regression failed and drove the evidence-frontier extension trigger.
An intermediate Swift exclusivity error in context normalization was fixed before the final tests.
Final build warnings: AppIntents metadata skipped (no AppIntents dependency). No baseline failure.

Local evidence directory: `/tmp/prts-continuity/`.
- baseline-core.log, baseline-contracts.log, baseline-python.log
- regression-before.log, core-exclusivity-repair.log
- core-final-debug.log, core-final-release.log, contracts-final.log, python-final.log
- normal-release.log, dev-simulator-tests.log, replay-verified.jsonl

Old compact run: 110 timestamps, **0 verified routes** under the new default. This is a diagnostic
coverage result, not a real-world passability judgment or an optimization success statistic.
Details and replay limitations are in the implementation report. No sensor recordings enter Git.

## Delivered binary and commits

- `b415eb7`: core world evidence / rolling-prefix / publication contracts and 22 new tests.
- `e0ac330`: atomic app publication, recording-policy separation, renderer expiry cache fix,
  diagnostics/settings/replay/documentation and build16. This is the compiled source revision.
- The earlier `79f853e` pending commit was also included in the fast-forward push; no reset/rewrite.
- Push to origin/main confirmed through `e0ac330`; this delivery-record update is documentation only.

Signed command:
```sh
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/prts-continuity/signed \
  -xcconfig configs/DevCapture.xcconfig PRTS_SOURCE_COMMIT=e0ac3306412e293d4c111689c5f16c05322e9f94 build
codesign --verify --deep --strict /tmp/prts-continuity/signed/Build/Products/Release-iphoneos/PRTS.app
```

Product metadata verified build16, bundle `com.jingxuan.PRTS`, source revision above; compiled Dev
privacy string confirms `PRTS_DEV_CAPTURE` inclusion. Ordinary build metadata explicitly reports
commit unavailable when no command-line revision was supplied. Same planning policy in both.

At 22:43:48–22:43:55 Asia/Shanghai, devicectl confirmed install and successful launch. Existing
application data was retained; no uninstall or erase. This does not certify sensor alignment,
route availability, physical obstacle avoidance, microphone/speech behavior or sustained thermals.
No camera test or unprotected walking was performed by the agent.

Log/binary identity hashes and structured outcomes: [evidence manifest](ROUTE_CONTINUITY_EVIDENCE_2026-09-29.json).
Full logs remain local under `/tmp/prts-continuity/`; temporary storage may be cleaned by the OS.
Do not interpret missing old raw data, compact reconstruction, or compilation as device acceptance.
