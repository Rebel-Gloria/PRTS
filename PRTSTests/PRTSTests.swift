import Foundation
import CoreVideo
import SpatialCore
import Testing
@testable import PRTS

struct PRTSTests {
    @Test func turnSpeechAnnouncesOnceAndRearmsAfterAlignment() throws {
        func heading(_ angle: Float) throws -> PathHeading {
            let data = try JSONSerialization.data(withJSONObject:["angleDegrees":angle,
                "crossTrack":0,"startDistance":0,"target":[0,0,1],"remainingLength":1])
            return try JSONDecoder().decode(PathHeading.self,from:data)
        }
        var policy = TurnAnnouncementPolicy()
        let left = try heading(-20), right = try heading(20), center = try heading(0)
        #expect(policy.update(heading:left,now:0,threshold:12,alignment:5) == -1)
        #expect(policy.update(heading:left,now:0.1,threshold:12,alignment:5) == nil)
        #expect(policy.update(heading:nil,now:0.2,threshold:12,alignment:5) == nil)
        #expect(policy.update(heading:left,now:0.3,threshold:12,alignment:5) == nil)
        #expect(policy.update(heading:right,now:0.4,threshold:12,alignment:5) == 1)
        for t in [0.5,0.6,0.7,0.8] {
            #expect(policy.update(heading:center,now:t,threshold:12,alignment:5) == nil)
        }
        #expect(policy.update(heading:right,now:0.9,threshold:12,alignment:5) == nil)
        #expect(policy.update(heading:right,now:1.0,threshold:12,alignment:5) == nil)
        #expect(policy.update(heading:right,now:1.1,threshold:12,alignment:5) == nil)
        #expect(policy.update(heading:right,now:1.2,threshold:12,alignment:5) == 1)
        #expect(policy.update(heading:right,now:1.3,threshold:12,alignment:5) == nil)
        policy.reset()
        #expect(policy.update(heading:left,now:2,threshold:12,alignment:5) == -1)
    }

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
