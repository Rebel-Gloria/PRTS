import Testing

@testable import PRTS

struct RGBCameraRecoveryTests {
    private func expectRecovery(_ expected: Bool, _ recovery: inout RGBCameraRecovery) {
        let requested = recovery.takeRecoveryRequest()
        #expect(requested == expected)
    }

    @Test func ordinaryFocusChangesNeverRequestCameraRecovery() {
        var recovery = RGBCameraRecovery()
        recovery.requestStart()
        recovery.setSceneActive(true)
        expectRecovery(false, &recovery)
        recovery.setSceneActive(false)
        recovery.setSceneActive(true)
        expectRecovery(false, &recovery)
    }

    @Test func mediaResetInBackgroundWaitsForForegroundAndRunsOnce() {
        var recovery = RGBCameraRecovery()
        recovery.requestStart()
        recovery.mediaServicesReset()
        expectRecovery(false, &recovery)
        recovery.setSceneActive(true)
        expectRecovery(true, &recovery)
        expectRecovery(false, &recovery)
        recovery.setSceneActive(false)
        recovery.setSceneActive(true)
        expectRecovery(false, &recovery)
    }

    @Test func explicitStopCancelsDeferredResetRecovery() {
        var recovery = RGBCameraRecovery()
        recovery.requestStart()
        recovery.mediaServicesReset()
        recovery.requestStop()
        recovery.setSceneActive(true)
        expectRecovery(false, &recovery)
        #expect(!recovery.requested)
    }

    @Test func resetDuringSystemInterruptionWaitsForItsEnd() {
        var recovery = RGBCameraRecovery()
        recovery.requestStart()
        recovery.setSceneActive(true)
        recovery.setInterrupted(true)
        recovery.mediaServicesReset()
        expectRecovery(false, &recovery)
        recovery.setInterrupted(false)
        expectRecovery(true, &recovery)
        expectRecovery(false, &recovery)
    }

    @Test func manualStartSupersedesAResetForTheStoppedSession() {
        var recovery = RGBCameraRecovery()
        recovery.mediaServicesReset()
        recovery.setSceneActive(true)
        expectRecovery(false, &recovery)
        recovery.requestStart()
        expectRecovery(false, &recovery)
    }

    @Test func staleInterruptionAfterStopCannotBlockTheNextSession() {
        var recovery = RGBCameraRecovery()
        recovery.requestStart()
        recovery.setInterrupted(true)
        recovery.requestStop()
        recovery.setInterrupted(true)
        recovery.requestStart()
        recovery.setSceneActive(true)
        recovery.mediaServicesReset()
        #expect(!recovery.interrupted)
        expectRecovery(true, &recovery)
    }
}
