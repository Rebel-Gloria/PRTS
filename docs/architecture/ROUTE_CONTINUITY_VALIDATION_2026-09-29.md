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
| Signed Dev Release / physical install | Pending completion of delivery step |
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
