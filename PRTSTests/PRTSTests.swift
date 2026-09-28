import Foundation
import CoreVideo
import SpatialCore
import Testing
@testable import PRTS

struct PRTSTests {
    @Test func phaseOneRuntimeHasNoLargeModelProfiles() {
        #expect(PRTSRuntimeProfile.offlineGeometry.rawValue == "offlineGeometry")
    }

    @Test @MainActor func missingDetectorIsExplicitlyUnavailable() {
        let detector = UnavailableObstacleDetector()
        #expect(detector.capability == .unavailable(.modelNotBundled))
    }

    @Test @MainActor func feedbackCoordinatorStartsWithoutOldResultIdentity() {
        let coordinator = FeedbackCoordinator()
        #expect(coordinator.lastConsumedResultID == nil)
        #expect(coordinator.lastSpokenResultID == nil)
    }
    @Test @MainActor func emptyStoppedSnapshotNeverPublishesMeasuredGuidance() {
        #expect(SceneSnapshotAdapter.measuredResult(SharedSnapshot(),now:1) == nil)
    }

    @Test @MainActor func integratedCameraOwnsProbeEngineWithoutStartingCapture() {
        let camera = CameraManager()
        #expect(!camera.model.snapshot.running)
        #expect(camera.latestSceneResult == nil)
    }

    @Test func rendererAndMonocularModelAreBundled() {
        #expect(Bundle.main.url(forResource:"ProbeShaders.metal",withExtension:"txt") != nil)
        #expect(Bundle.main.url(forResource:"DepthAnythingV2SmallF16",withExtension:"mlmodelc") != nil)
    }
}
