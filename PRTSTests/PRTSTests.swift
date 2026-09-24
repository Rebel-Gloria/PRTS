import Testing
@testable import PRTS
import PRTSContracts
import PRTSAppleModels

struct PRTSTests {
    @Test @MainActor func pushTextUsesPinnedCommandContractWithoutPretendingModelsRan() {
        let bridge = PRTSBackendBridge()
        let intent = bridge.pushText("开始导航")
        #expect(intent?.action == "navigate")
        #expect(bridge.latestCommand.contains("Contract intent"))
        #expect(bridge.latestCommand.contains("models not running"))
    }

    @Test func defaultRuntimeIsMinimalAndDoesNotLoadLargeBrain() {
        let profile = PRTSRuntimeProfile.minimal
        #expect(!profile.enablesPerception)
        #expect(!profile.loadsLargeBrain)
        #expect(!PRTSAppleRuntimeCapability.coreSessionAvailable)
    }

    @Test func fullExperimentalIsExplicitAndPerceptionDoesNotLoadBrain() {
        #expect(PRTSRuntimeProfile.perception.enablesPerception)
        #expect(!PRTSRuntimeProfile.perception.loadsLargeBrain)
        #expect(PRTSRuntimeProfile.fullExperimental.loadsLargeBrain)
    }
}
