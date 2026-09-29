# Route continuity / verified evidence — round 1 (build 16)

## Scope and baseline

This is a running minimum closed loop, **not completion of every S0–S7 item**. It preserves the
straight/greedy/Dijkstra stack. No new library, model, service, ARSession or UI layout was added.

Baseline: `main`, `79f853e`. Remote was `462b937`. The only initial dirty file was the project
build-number update 14→15 from the preceding installation; it was preserved, then advanced to 16.
No applicable AGENTS.md was present in this checkout or its ancestors. Read README, PRTS/README,
architecture/data-flow, build/validation and Dev recording instructions before changes.

The user subsequently authorized atomic commits, push to main and a Dev installation per round.
The preceding build15 install is not validation of this implementation. Build14 recordings are
not assumed to match `79f853e` or the new binary.

## A. Findings: problem → cause → change → intended result

| Issue | Verified branch / cause | Round-1 change and remaining scope |
|---|---|---|
| P1 endpoint lifecycle | `ForwardRoutePlanner.update` cleared path/goal/maneuver on local arrival; `PathPresentation.make` independently hid near endpoint. | Verified routes no longer complete at a temporary endpoint. Advance tails on new evidence or renewal budget; retain identity. Synthetic moving corridor never has an empty output. No destination service was introduced. |
| P2 handoff | `ProbeEngine.drainAnalysis` cleared paths for ordinary target changes **before** checking result freshness. | `RoutePublicationPolicy.decide` commits whole PathUpdate under SharedStore lock. Expired/out-of-order normal candidates retain still-valid prefixes; current hazard preempts before search. |
| P3 observation memory | LocalGrid rotated with camera; SurfaceHistory was a drawing cache, not a complete planning map. | `RouteEvidenceMap` stores evidence by gravity/world cell index; camera-grid snapshots are query views. Epoch/body/reference conflict resets. Blue history remains separate. |
| P4 Dev policy | `#if PRTS_DEV_CAPTURE` selected `PathPredictor(experimentalOccupancyPlanning:true)` even without recording. TemporalOccupancyGrid opened unknown and suppressed current-depth veto. | Both app builds now use `PathPredictor()` → `verified_continuous_v1`. Experimental implementation remains explicit **offline comparison only**. No automatic Dev branch selection. |
| P5 persistence | `ObstaclePersistence` reset beyond 200ms; the experimental branch withheld all occupancy for 300ms. | Immediate spatially supported current hazard veto; separate 300ms side commitment, 750ms maximum association gap, missing hit cannot advance confirmation. Map memory does not masquerade as another sensor hit. Positive free evidence required to clear. |
| P6 evidence levels | build15 worldLocked and projection styling made predictions appear solid; old path revalidation updated global time without proof. | Verified paths carry interval observation/expiry. Current yellow / history orange dashed / projection pale-blue dashed; unobserved approach stays cyan dashed. Projection never supplies pathHeading or verified length. Per-segment mixed styling is not implemented. |
| P7 body envelope | Path minimum 0.50m vs default body 0.60+2×0.15=0.90m; RoutePlanningGrid admitted ground-only cells. | Default requires GridBuilder full-height candidate cells; width=max(requested,body+2margin). Same disk sweep in map/search/validation. No second body-radius inflation. Reprojection is conservative and may lose boundary cells. |
| P8 candidate quality | Existing greedy + Dijkstra and swept collision checks were already present. Shortest/farthest comparisons remain limited. | Retained search and simplification checks; unified envelope. **Unified clearance/stability scoring and graph cost change deferred**, not claimed solved. |
| P9 progress/intent | Unrestricted nearest-polyline match could jump to a hairpin return; yaw dwell treated phone observation as travel intent. Corner-aware lookahead already existed. | Bounded arc window with 20cm local reverse allowance; display uses committed geometry. Verified policy disables stationary yaw-only adoption. Existing corner stop retained. Full global progressS, motion-based intent and deliberate U-turn adoption deferred; stop/start selects a new forward intent meanwhile. |
| P10 attribution | Path/graphics logs existed, but lacked map/geometry/watermark and atomic publication reasons. | Route schema2 contexts link prediction/publication/render. Actual analysis start/end, processed-capture interval, publish and drawable-present timestamps are available. No claimed hardware RGB/LiDAR delta or measured walking performance. |

These are code-confirmed mechanisms and deterministic reproductions. Their relative contribution
to each old video remains unknown without matching commit/configuration and dense sensor evidence.

## B. State and execution chain

```text
ARFrame / calibrated DA + pose
  → bounded latest-frame mailbox, one serial analysis worker
  → Depth / Ground / GridBuilder full-height visibility
  → RouteSafety current cluster veto → SharedStore hazard watermark (before search)
  → RouteEvidenceMap ingest (world fixed, actual measurement stamps)
  → supported prefix + bounded progress
  → ForwardRoutePlanner: straight extension → greedy detour → Dijkstra fallback
  → complete swept-body proof from map
  → RoutePublicationPolicy: epoch / parameters / barrier / order / hazard / freshness
  → one SharedStore PathUpdate (geometry + proof + context)
  → PathPresentation + PathTracking → rendering / haptics / speech
```

`PathPredictor` owns map, planner and prior output on the analysis worker. There is no independent
unbounded planner task queue to replace. Frame ID serves as request ID in this serial architecture.
It is not a general asynchronous multi-planner coordinator. Publication rejects pre-hazard results,
and unrelated global map version changes do not cause equality-based starvation.

`PredictedPath.id` stays stable through tail extension. `geometryVersion` changes with geometry
(including progress trimming). The existing `FixedPathGoal` is a **local horizon**, not arrival at
an external destination. RouteContext includes source map version, tracking epoch, parameter
version, hazard watermark, remaining verified length and oldest proof age. There is not yet a
separate global intentID, full-path progressS or destination object.

Normal late candidates preserve the valid old prefix. Validity is per arc interval; an expired
suffix is cut, not restamped. A current supported obstacle cluster withdraws the conflicting route
before search; this first iteration withdraws the whole conflicting route, then publishes a valid
prefix/detour if available. Fine-grained hazard truncation before search is a follow-up.

Latest raw depth is checked against retained and new paths. A lone pixel does not veto; existing
confidence/height and spatial support checks are reused. Slow commitment requires real repeated
obstacle evidence, not repeated reads from memory. Missing data never clears occupied cells.

### Evidence map

World cell coordinates use a fixed basis from the first ground plane and gravity. The dictionary
retains a bounded 6m-radius window, prunes expired cells, and initializes new positions as unknown.
Resolution remains the existing 0.1m; current acquisition range remains 4m × 3m. This does **not**
increase sensor range. `ProbeParameters.validated()` still pins that acquisition grid configuration.

A cell stores ground/free/occupied times, clear-evidence dwell and source frame; epoch/parameter
identity belongs to the map. Free writes require **current** confirmed ground plus GridBuilder's
full-height candidate classification. Ground-only surfaces, missing depth and fitted infinite
planes cannot write free. Expired occupancy becomes unknown, not free. Clearing needs successive
positive free observations, not elapsed time alone.

This is memory of already-tested **full-height cell verdicts**. It is not yet fusion of independently
observed height layers across frames, calibrated probability, uncertainty modeling, or a reusable
export of the entire map. Floor-only / suspected evidence is conservatively unknown. Suspected
samples revoke old free proof but do not alone become a stable obstacle track.

Initial, uncalibrated defaults (constructor configurable and recorded in manifest):
- ground TTL 1s; full-height clearance TTL 0.5s; occupancy TTL 1.5s; clearing dwell 0.15s;
- side commitment 0.3s, maximum association gap 0.75s;
- renewal minimum 1.5m, initial pipeline **budget** 0.25s, reserve 0.8s, margin 0.3m;
- renewal=max(minimum,clamped estimated speed×(budget+reserve)+margin).

The budget is not measured pipeline P95 or human stopping distance. A supported tail gain of
>0.30m also triggers extension before the budget is exhausted (>0.15m within renewal distance).
Only tails ending on the intent axis may extend straight; no shortcut across a detour is added.
Connections and candidate segments must pass the full envelope. Near geometry is not rebuilt just
because more far geometry became visible.

### Presentation/feedback

Unknown near-body connection is never upgraded by the displayed connector. For verified paths,
heading feedback pauses if the unverified approach exceeds 0.25m, the remaining segment is <0.25m,
tracking/direction is invalid, or proof expires. Chest-held camera blind spots may therefore leave
an observed remote segment on screen without turn guidance. This is an explicit current limitation.

All feedback consumes the same committed PathUpdate. Pure projection cannot trigger turn feedback.
Existing haptic/once-per-stage speech ownership is retained. Historical styling is currently applied
to the entire displayed line if any of its proof is old; intervals are finer than the visual styling.
Main page structure, theme, developer-only controls and resources are unchanged. Developer settings remove obsolete endpoint-arrival/yaw-dwell controls and show the effective body envelope. Render cache keys include the entire current geometry so between-frame proof expiry cannot leave an old tail buffer visible.

## C. Tests and evidence

Artifacts: `/tmp/prts-continuity/` (local, not sensor data committed to Git).
Baseline: 248 SpatialCore tests, 8 contract tests, 45 Python tests passed.
Three new regression cases failed before implementation (ground-only authorization, 0.9m body
width, display hiding near local end), then passed. No baseline failure was relabeled as new.

Executed validation commands:
```sh
swift test --package-path Vendor/SpatialCore
swift test -c release --package-path Vendor/SpatialCore
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore
python3 -m unittest discover -s scripts -p 'test_*.py'
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/prts-continuity/normal CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Debug \
  -destination 'platform=iOS Simulator,id=C6C8584E-5D03-4F9A-8B78-DD69BCC4194C' \
  -derivedDataPath /tmp/prts-continuity/simulator -xcconfig configs/DevCapture.xcconfig \
  CODE_SIGNING_ALLOWED=NO -only-testing:PRTSTests test
```

Final build/test/install results are in the [round delivery record](ROUTE_CONTINUITY_VALIDATION_2026-09-29.md). No sleeps in the new core tests:
clocks/event orders are explicit numeric inputs. New 22 tests + existing 248 cover:
- rolling extension, near-end display, late/old candidate retention and bounded expiry;
- hazard watermark, current clustered depth versus isolated pixel, epoch/body/barrier rejection;
- unknown vs ground-only vs body-clear, expiry without refresh, expired suffix preservation;
- world position under yaw, rolling-window eviction, dynamic occupancy positive clearing;
- 100/200/210/300ms cadence, missed frame and long gap, single ghost not multi-hit;
- progress on hairpins, consistent envelope in narrow/wide corridors.

Existing suites retain suspended-obstacle, corner/simplification, epoch/order, projection and
feedback tests. Source-contract tests now check intentional main runtime evolution instead of
incorrectly requiring byte identity with the frozen experiment. Unmodified clearance math and
frozen resources still have parity checks. Recording invariance is checked by common runtime
construction and both builds; equal real-time scheduling under recording load is **not** promised.

### Old recording: a negative result, not a success metric

Read-only input: `TestData/2026-09-29-latest-2041/compact-epoch4-input.jsonl` in the sibling data
folder, reconstructed from the build14 run. 110 actual analysis timestamps; 109,108 unknown,
10,769 occupied and **123 candidate cell observations**. Counts sum cell observations across
frames, not independent real-world area; missing-grid frames are excluded.

New-policy replay produces **0/110 verified routes** (65 near-obstacle/no observed detour,
33 pending obstacle, 11 waiting ground, 1 reference conflict). This exposes insufficient saved
body-clear evidence; it does not establish that reality had no path. The old aggressive route
output is not an independent truth label. We do not claim an availability improvement on this run.

Compact reconstruction lacks exact per-cell sample counts and full raw depth veto. The 31 paired
low-rate capture samples cannot reproduce every subsecond sensor event. No interpolated hits were
created. Replay validates evidence/state handling, not real collision rate or UI continuity.
The positive availability test is the synthetic continuously observed corridor, labeled synthetic.
A new dense diagnostic run is required to determine whether layer-wise fusion is the next bottleneck.

## D. Log/replay compatibility

Binary diagnostic attachment format remains unchanged. New optional fields in PathUpdate and
PredictedPath preserve decoding of old records; missing context means **unavailable**, not invented
verified proof. New `path.jsonl` records have schemaVersion=2 and phase=prediction/publication.
- RouteContext: policy, epoch/frame/request/map/route/geometry/parameter IDs, watermark, proof age,
  verified length, renewal budget and width.
- Publication: candidate/published contexts, reason, publishTime, analysisStart/End,
  actualAnalysisInterval (processed capture timestamps), captureEnabled and thermalState.
- Rendering: submitted context/reason/time and **routeDisplayedVerifiedLength**, actual renderID;
  correlate existing GPU completion/drawable present records by renderID.
- Manifest: build/configuration/commit, policy, schema and initial map/renewal options.

Do not treat recorded vertex counts or pure projection as a verified route. `PRTSCommit` comes from
`PRTS_SOURCE_COMMIT`; manual builds without the supplied setting say unavailable. Low-rate capture
and Dev options do not choose planning policy. Feedback retains its existing frame/path ID linkage;
a separate geometry-version feedback field and automated end-to-end percentile report remain open.

`replay_route_snapshots.swift` defaults to the new verified policy. Historical comparison must pass
`--experimental-occupancy` explicitly. Preserve frame timestamps/order. Build example in scripts/README.
The old recorder/reader format is still supported. No recordings, videos or original images are uploaded.

## E. Controlled device validation (not performed by the agent)

Use a sighted tester and stationary/slow protected trials; no blind obstacle crossing.
1. Wide clear corridor: scan floor/body space, then walk slowly along a marked 4m line with assistance.
   Record timestamps when a local horizon is approached; inspect overlapping tail commits and reason
   for any absence. Compare current/history/projection/none **separately**.
2. Stationary yaw ±60°, brief 100–300ms occlusion, then restore view. Check world placement and
   actual proof expiry; a long unseen interval must not keep proof alive indefinitely.
3. Place a cardboard box into the current route while stationary. Capture first supported cluster,
   hazard event, publication and presentation; no old candidate may restore the obstructed segment.
   Remove box and observe fresh clearing evidence before recovery.
4. Table/overhead object and measured narrow/wide lanes: verify displayed width matches body setting;
   no attempt to traverse a questionable lane. Follow a marked hairpin in an empty area for progress.
5. Repeat with Dev recording off/on, lifecycle interruption and session reset; compare policy/config,
   accepted route identities, drops, analysis intervals, source-to-drawable latency and thermal state.

Independently annotate valid corridor periods and obstacle volumes (tape measure + reference video).
Compute route absence durations, lateral/head-angle change, side switches, forbidden-space conflicts,
hazard-to-withdraw latency, source-to-display/feedback latency distributions, queue/memory/thermal.
Without those labels report internal consistency only. No measured error, FPS, P95, energy or improvement
percentage is supplied by this round. Start with short tests, then a 30-minute thermal run.

## F. Next independently reviewable rounds

1. Dense real replay + height-layer evidence fusion, diagnosed from new recorded coverage; avoid relaxing
   unknown semantics to conceal this round's 0/110 result. Export relevant map snapshots for reproduction.
2. Per-segment fast hazard truncation, route corridor/progress state with bounded real backtracking,
   motion-based intent adoption and explicit direction override; no yaw-only destination inference.
3. Unified normalized clearance/change/turn/progress candidate score; nonnegative graph edges and
   quality-preserving simplification. Existing shortest/farthest scoring has not been replaced.
4. Per-segment current/history styling and structured no-route reasons across all lifecycle paths;
   geometry-version feedback linkage, measured pipeline percentile estimator and public tunable config.
5. Phone/body offset, glass/reflective/negative-obstacle blind spots, DA metric scale and classification
   errors still require real tests. ARKit can miss obstacles. Nothing here certifies a walking route.
