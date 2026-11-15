import Testing

@testable import PRTS

struct RGBCameraRecoveryTests {
    @Test func ordinaryFocusChangesNeverRequestCameraRecovery() {
        var recovery = RGBCameraRecovery()
        recovery.requestStart()
        recovery.setSceneActive(true)
        #expect(!recovery.takeRecoveryRequest())
        recovery.setSceneActive(false)
        recovery.setSceneActive(true)
        #expect(!recovery.takeRecoveryRequest())
    }

    @Test func mediaResetInBackgroundWaitsForForegroundAndRunsOnce() {
        var recovery = RGBCameraRecovery()
        recovery.requestStart()
        recovery.mediaServicesReset()
        #expect(!recovery.takeRecoveryRequest())
        recovery.setSceneActive(true)
        #expect(recovery.takeRecoveryRequest())
        #expect(!recovery.takeRecoveryRequest())
        recovery.setSceneActive(false)
        recovery.setSceneActive(true)
        #expect(!recovery.takeRecoveryRequest())
    }

    @Test func explicitStopCancelsDeferredResetRecovery() {
        var recovery = RGBCameraRecovery()
        recovery.requestStart()
        recovery.mediaServicesReset()
        recovery.requestStop()
        recovery.setSceneActive(true)
        #expect(!recovery.takeRecoveryRequest())
        #expect(!recovery.requested)
    }

    @Test func resetDuringSystemInterruptionWaitsForItsEnd() {
        var recovery = RGBCameraRecovery()
        recovery.requestStart()
        recovery.setSceneActive(true)
        recovery.setInterrupted(true)
        recovery.mediaServicesReset()
        #expect(!recovery.takeRecoveryRequest())
        recovery.setInterrupted(false)
        #expect(recovery.takeRecoveryRequest())
        #expect(!recovery.takeRecoveryRequest())
    }

    @Test func manualStartSupersedesAResetForTheStoppedSession() {
        var recovery = RGBCameraRecovery()
        recovery.mediaServicesReset()
        recovery.setSceneActive(true)
        #expect(!recovery.takeRecoveryRequest())
        recovery.requestStart()
        #expect(!recovery.takeRecoveryRequest())
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
        #expect(recovery.takeRecoveryRequest())
    }
}
