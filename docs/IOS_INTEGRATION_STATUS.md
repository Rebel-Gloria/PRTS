# iOS integration status (2026-09-24)

## Implemented in this phase

- The Xcode project references the local `Vendor/PRTSCore` package and links `PRTSContracts` plus the available `PRTSAppleModels` module.
- The package uses the exact backend pin documented in `PRTS_CORE_VENDORING.md`; when the VLM XCFramework is absent, SwiftPM compiles the actual lightweight BGRA-to-RGB `CameraAdapter` and capability report, not the heavy session target.
- `PRTSBackendBridge` implements a bounded newest-sample ingress (at most 5 converted frames/s), converts `CMSampleBuffer` image buffers off the camera callback and off the main thread, uses `ProcessInfo.systemUptime`, assigns increasing sequence numbers, and publishes the newest converted frame to SwiftUI without creating an unbounded main-actor task queue.
- The current bridge explicitly does **not** call `PRTSCoreSession.pushVideo` or claim model output: no `PRTSCoreSession` module can be built without the upstream XCFramework and runtimes. Converted frames are presently measured and retained as a bridge smoke path.
- `pushText` smoke validation uses the pinned `PRTSContracts.CommandRouter` to yield a typed `TaskIntent`; the UI labels it “Contract intent” and “models not running”. This is a contract/parser integration check, not a full navigation/session event.
- `CoreEvent` has a main-actor delivery point for speech requests, cancellation, cue and attention events. The existing `SpeechManager` preserves language/rate settings and handles priority, expiry, replacement, bounded pending requests, cancellation, and actual synthesizer delegate start/finish/cancel signals. Playback is not marked active merely on receipt.
- Minimal, perception, and full/experimental profiles are explicit. Brain, perception, ASR, and map switches are independent; minimal is the default. Memory warning pauses ingress and downgrades full/experimental to perception. Backgrounding pauses ingress and foregrounding can resume it; termination closes the bridge.
- Existing HapticManager remains the single haptics implementation. No microphone/PCM capture is enabled.

## Not available / not claimed

The pinned Apple package snapshot lacks `Artifacts/prts_vlm.xcframework` and packaged weights/manifests for semantic segmentation, detector, VLM/projector, and SenseVoice. The app therefore does not load Mask2Former, YOLO, ASR, VLM, map, or cerebellum models. Maps and ASR switches are reserved gates, not functional features yet. `PRTSCoreSession` currently constructs all native model components eagerly; changing that initialization safely requires the actual runtime artifacts and collaborator validation, so this integration keeps the full target entirely out of the default app build.

No Apple model optimization was run: no source model files were provided, so there are no valid baseline outputs, hashes, conversion measurements, or device performance results to report. CPU/CoreML Execution Provider/native Core ML comparisons, ASR conversion, and VLM quantization remain blocked on model files. No iPhone 15 Pro measurements have been performed. The desktop-reported multi-GB peak remains a significant risk; `full/experimental` is not a recommended phone mode.

This build is an engineering integration and controlled-test scaffold, not a real-world mobility/safety aid.

## Manual iPhone 15 Pro smoke procedure

1. Open `PRTS.xcodeproj` in Xcode and select the PRTS app scheme.
2. Connect an iPhone 15 Pro running a supported iOS version; select it as the run destination. Choose a Personal Team under Signing & Capabilities only if Xcode requires it for device install. Do not put a Team ID in project settings.
3. Start with Runtime profile `minimal`; keep brain, perception, ASR, and maps disabled.
4. Build/run, grant camera access, start the camera, verify the backend panel stays in the explicit models-unavailable state and the converted-frame counter advances. Stop, background/foreground, visit Settings, and repeat start/stop to look for duplicate sessions or stale callbacks.
5. Enter `开始导航` into the test-command field. Verify the displayed contract intent is `navigate` and clearly says models are not running. This should not claim a route was started or speak a fabricated navigation result.
6. Test voice settings through the existing settings controls. Full backend speech-request and playback feedback cannot be exercised until an actual CoreEvent producer/session is supplied.
7. Optionally use Xcode Memory Graph/Instruments on the connected device for the camera-only path. Record the device/OS and observed memory; do not extrapolate this to unavailable model modes.

## Build and test commands

```sh
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore
swift build --package-path Vendor/PRTSCore
xcodebuild -project PRTS.xcodeproj -scheme PRTS -sdk iphoneos \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PRTS.xcodeproj -scheme PRTS -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing
```
