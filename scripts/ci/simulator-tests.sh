#!/usr/bin/env bash
# Run every test except cases requiring hardware, real weights or device performance measurements.
set -eu
skip=(-skip-testing:PRTSTests/PhotoLocalModelTests)
for name in testRunningCameraStatusMatchesLowVisionSetting testLowVisionRequiresConfirmationAndCancellationKeepsItOff testCameraResumesOnlyAfterUserStartsIt testGuidanceRestartsAfterHoldToStop testNoPreviewModeSkipsRendering testTextReadingStartsCamera testScreenTour testCPUWithPreview testCPUWithoutPreview testLaunchPerformance; do
    skip+=("-skip-testing:PRTSUITests/PRTSUITests/$name")
done
for name in testAssistiveTouchTapStopsGuidanceWithoutRestarting testReadingInterruptedByBackgroundResumesGuidance testReadingInterruptedBySettingsResumesGuidance testReadingFromIdleDoesNotStartGuidanceAfterBackground; do
    skip+=("-skip-testing:PRTSUITests/GuidanceRecoveryUITests/$name")
done
skip+=(-skip-testing:PRTSUITests/PermissionSetupUITests/testPrepareCameraAndSpeechPermissions)
exec xcodebuild "$@" "${skip[@]}" -parallel-testing-enabled NO test-without-building
