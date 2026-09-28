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
    @Test func displayOptionsRemainBackwardCompatible() throws {
        let old = RenderOptions()
        var json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as? [String:Any])
        for key in ["cameraImageVisible","geometryOverlaysVisible","pathVisible","legendsVisible"] { json.removeValue(forKey:key) }
        let decoded = try JSONDecoder().decode(RenderOptions.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(decoded.showCameraImage && decoded.showOverlays && decoded.showPath && decoded.showLegends)
        var hidden = decoded
        hidden.showCameraImage = false; hidden.showOverlays = false; hidden.showPath = false; hidden.showHUD = false
        #expect(try JSONDecoder().decode(RenderOptions.self,from:JSONEncoder().encode(hidden)) == hidden)
        #expect(hidden.showSurfaceModel == old.showSurfaceModel)
    }
    @Test @MainActor func settingsSpeechBuildsLocalizedAnnouncement() {
        let speech = SpeechManager()
        speech.speakSettingsScreen(hapticFeedbackEnabled:true)
        #expect(speech.lastSettingsAnnouncement?.isEmpty == false)
        #expect(speech.lastSettingsAnnouncement != "speech.settings.summary")
        speech.cancelPerceptionSpeech()
        #expect(speech.lastSettingsAnnouncement?.isEmpty == false)
        speech.stopCurrentSpeech()
    }
}
