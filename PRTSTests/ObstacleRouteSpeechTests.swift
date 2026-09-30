import Foundation
import Testing
import SpatialCore
@testable import PRTS

@MainActor
struct ObstacleRouteSpeechTests {
    private func heading(_ angle: Float) throws -> PathHeading {
        try JSONDecoder().decode(PathHeading.self,from:JSONSerialization.data(withJSONObject:[
            "angleDegrees":angle,"crossTrack":0,"startDistance":0,"target":[0,0,-1],"remainingLength":1]))
    }
    private func update(_ scenario: String, goal: UInt64 = 10, distance: Float = 1.4) throws -> PathUpdate {
        var u = PathUpdate(reason:scenario)
        u.waypointGuidance = try JSONDecoder().decode(ObstacleWaypointGuidance.self,from:JSONSerialization.data(withJSONObject:[
            "schemaVersion":1,"scenario":scenario,"obstacleDistance":distance,
            "stationaryTurnSeconds":0,"referenceForward":[0,0,-1],"nextTarget":[2,0,-2]]))
        if scenario != "clear" && scenario != "blocked" {
            u.path = try JSONDecoder().decode(PredictedPath.self,from:JSONSerialization.data(withJSONObject:[
                "id":goal,"epoch":1,"parameterVersion":0,"sourceFrameID":1,"validatedFrameID":1,
                "observedAt":1,"plane":["normal":[0,1,0],"offset":0,"residual":0,"supportCount":0,"supportArea":0,"floorPriorConfirmed":true],
                "points":[[0,0,0],[-0.5,0,-1]],"source":"synthetic","requiredWidth":0.5,"planningPolicy":"obstacle_veto_v1"]))
            u.goal = try JSONDecoder().decode(FixedPathGoal.self,from:JSONSerialization.data(withJSONObject:[
                "id":goal,"epoch":1,"point":[-0.5,0,-1],"plane":["normal":[0,1,0],"offset":0,"residual":0,"supportCount":0,"supportArea":0,"floorPriorConfirmed":true],
                "selectedAt":1,"maxDistance":8]))
        }
        return u
    }

    @Test func openSpaceSpeaksOnceWithoutAPath() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let u = try update("clear")
        #expect(policy.cue(update:u,heading:nil,now:1,deviationDegrees:12) == .clear)
        #expect(policy.cue(update:u,heading:nil,now:10,deviationDegrees:12) == nil)
        #expect(ObstacleRouteSpeech.clear.chinese == "前方无障碍")
    }
    @Test func distantObstacleAnnouncesDistanceNotPreviewTurn() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let cue = policy.cue(update:try update("distantObstacle",distance:3),heading:try heading(30),now:1,deviationDegrees:12)
        #expect(cue == .obstacle(3,nil))
        #expect(cue?.chinese == "前方障碍，约 3.0 米")
    }
    @Test func nearObstacleCombinesDistanceAndCurrentTurn() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let cue = policy.cue(update:try update("nearObstacle"),heading:try heading(-25),now:1,deviationDegrees:12)
        #expect(cue == .obstacle(1.4,-1))
        #expect(cue?.chinese == "前方障碍，约 1.4 米，向左转")
        #expect(policy.cue(update:try update("nearObstacle"),heading:try heading(-25),now:1.1,deviationDegrees:12) == nil)
    }
    @Test func previewChangesCannotTriggerAnotherTurn() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        var u = try update("nearObstacle")
        _ = policy.cue(update:u,heading:try heading(-25),now:1,deviationDegrees:12)
        u.waypointGuidance?.nextTarget = SIMD3(-3,0,-2)
        u.waypointGuidance?.nextPreparedAt = 1.2
        #expect(policy.cue(update:u,heading:try heading(-25),now:1.2,deviationDegrees:12) == nil)
        // Only promotion to a new committed identity allows its turn instruction.
        #expect(policy.cue(update:try update("nearObstacle",goal:11),heading:try heading(25),now:1.3,deviationDegrees:12) == .obstacle(1.4,1))
    }
    @Test func unavailableHeadingCannotSpeakAPreviewDirection() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(policy.cue(update:try update("nearObstacle"),heading:nil,now:1,deviationDegrees:12) == .obstacle(1.4,nil))
        #expect(policy.cue(update:try update("nearObstacle"),heading:try heading(25),now:1.1,deviationDegrees:12) == .obstacle(1.4,1))
    }
    @Test func distanceUpdatesHaveAMinimumInterval() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        _ = policy.cue(update:try update("distantObstacle",distance:4),heading:nil,now:1,deviationDegrees:12)
        #expect(policy.cue(update:try update("distantObstacle",distance:3.4),heading:nil,now:2,deviationDegrees:12) == nil)
        #expect(policy.cue(update:try update("distantObstacle",distance:3.4),heading:nil,now:4,deviationDegrees:12) == .obstacle(3.4,nil))
    }
    @Test func blockedAndRecoveryHaveDistinctCues() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let cue = policy.cue(update:try update("blocked"),heading:try heading(-40),now:1,deviationDegrees:12)
        #expect(cue == .blocked(1.4))
        #expect(cue?.chinese.contains("暂无绕行路径") == true)
        #expect(policy.cue(update:try update("clear"),heading:nil,now:2,deviationDegrees:12) == .clear)
    }
    @Test func resetRearmsOpenSpaceAnnouncement() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let u = try update("clear")
        _ = policy.cue(update:u,heading:nil,now:1,deviationDegrees:12)
        policy.reset()
        #expect(policy.cue(update:u,heading:nil,now:2,deviationDegrees:12) == .clear)
    }
}

extension ObstacleRouteSpeechTests {
    @Test func offscreenGoalFailureRequestsCameraAdjustment() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        var u = try update("blocked")
        u.reason = "no_visible_target"
        let cue = policy.cue(update:u,heading:nil,now:1,deviationDegrees:12)
        #expect(cue == .adjustCamera(1.4))
        #expect(cue?.chinese == "前方障碍，约 1.4 米，请调整手机方向")
    }
}
