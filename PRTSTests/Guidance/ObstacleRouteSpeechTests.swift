import Foundation
import SpatialCore
import Testing

@testable import PRTS

@MainActor
struct ObstacleRouteSpeechTests {
    private func heading(_ angle: Float) throws -> PathHeading {
        try JSONDecoder().decode(
            PathHeading.self,
            from: JSONSerialization.data(withJSONObject: [
                "angleDegrees": angle, "crossTrack": 0, "startDistance": 0, "target": [0, 0, -1],
                "remainingLength": 1,
            ])
        )
    }
    private func update(_ scenario: String, goal: UInt64 = 10, distance: Float = 1.4) throws
        -> PathUpdate
    {
        var u = PathUpdate(reason: scenario)
        u.waypointGuidance = try JSONDecoder().decode(
            ObstacleWaypointGuidance.self,
            from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "scenario": scenario, "obstacleDistance": distance,
                "stationaryTurnSeconds": 0, "referenceForward": [0, 0, -1],
                "nextTarget": [2, 0, -2],
            ])
        )
        if scenario != "clear" && scenario != "blocked" {
            u.path = try JSONDecoder().decode(
                PredictedPath.self,
                from: JSONSerialization.data(withJSONObject: [
                    "id": goal, "epoch": 1, "parameterVersion": 0, "sourceFrameID": 1,
                    "validatedFrameID": 1,
                    "observedAt": 1,
                    "plane": [
                        "normal": [0, 1, 0], "offset": 0, "residual": 0, "supportCount": 0,
                        "supportArea": 0, "floorPriorConfirmed": true,
                    ],
                    "points": [[0, 0, 0], [-0.5, 0, -1]], "source": "synthetic",
                    "requiredWidth": 0.5, "planningPolicy": "obstacle_veto_v1",
                ])
            )
            u.goal = try JSONDecoder().decode(
                FixedPathGoal.self,
                from: JSONSerialization.data(withJSONObject: [
                    "id": goal, "epoch": 1, "point": [-0.5, 0, -1],
                    "plane": [
                        "normal": [0, 1, 0], "offset": 0, "residual": 0, "supportCount": 0,
                        "supportArea": 0, "floorPriorConfirmed": true,
                    ],
                    "selectedAt": 1, "maxDistance": 8,
                ])
            )
        }
        return u
    }

    private func context(measuredAt time: Double) throws -> RouteContext {
        let id = Int(time * 100)
        return try JSONDecoder().decode(
            RouteContext.self,
            from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 4, "planningPolicy": RoutePlanningPolicy.obstacleVeto.rawValue,
                "epoch": 1, "parameterVersion": 0, "frameID": id, "timestamp": time,
                "requestID": id, "sourceMapVersion": 1, "hazardWatermark": 0, "geometryVersion": 1,
                "status": "clear", "remainingVerifiedLength": 0, "renewalDistance": 1,
                "pipelineBudgetSource": "test", "requiredWidth": 0.5,
            ])
        )
    }

    private func clearCue(
        _ policy: inout ObstacleRouteAnnouncementPolicy,
        measuredAt time: Double,
        now: Double? = nil,
        maxResultAge: Double = 0.25
    ) throws -> ObstacleRouteSpeech? {
        var clear = try update("clear")
        clear.continuity = try context(measuredAt: time)
        return policy.cue(
            update: clear,
            heading: nil,
            now: now ?? time,
            deviationDegrees: 12,
            maxResultAge: maxResultAge
        )
    }

    @Test func fullFieldObstacleWarnsImmediatelyOnceAcrossPollsAndBriefHoles() {
        var policy = ObstacleRouteAnnouncementPolicy()
        let first = policy.fullFieldCue(measuredAt: 10)
        #expect(first == .close)
        #expect(first?.chinese == "障碍很近")
        #expect(first?.english == "Obstacle close")
        for tick in 100...139 {
            policy.pauseObservations()
            #expect(policy.fullFieldCue(measuredAt: Double(tick) / 10) == nil)
        }
        policy.pauseObservations()
        #expect(policy.fullFieldCue(measuredAt: 14.5) == nil)
        #expect(policy.fullFieldCue(measuredAt: 17) == .close)
    }

    @Test func recoveryFromFullFieldObstacleRequiresNewClearMeasurements() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(try clearCue(&policy, measuredAt: 1) == nil)
        #expect(policy.fullFieldCue(measuredAt: 1.1) == .close)
        for tick in 12...16 {
            #expect(try clearCue(&policy, measuredAt: Double(tick) / 10) == nil)
        }
        #expect(try clearCue(&policy, measuredAt: 1.7) == .clear)
        #expect(!policy.lastCueWasFullField)
        #expect(policy.fullFieldCue(measuredAt: 1.8) == .close)
    }

    @Test func heldObstacleCannotStartFeedbackButStillRevokesAnObsoleteTurn() throws {
        var hazard = try update("nearObstacle")
        hazard.continuity = try context(measuredAt: 2)
        #expect(hazard.canStartWaypointFeedback(now: 2.1, maxAge: 0.25))
        #expect(!hazard.canStartWaypointFeedback(now: 2.4, maxAge: 0.25))
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(
            policy.cue(update: hazard, heading: try heading(-25), now: 2, deviationDegrees: 12)
                == .obstacle(1.4, -1)
        )
        hazard.waypointGuidance?.retainedObstacleAt = 2
        #expect(!hazard.canStartWaypointFeedback(now: 2.1, maxAge: 0.25))
        func shouldInterrupt(_ heading: PathHeading?) -> Bool {
            policy.interruptIfObsolete(
                update: hazard,
                heading: heading,
                threshold: 12,
                newObservation: false
            )
        }
        #expect(!shouldInterrupt(try heading(-25)))
        hazard.path = nil
        #expect(shouldInterrupt(nil))
        #expect(!shouldInterrupt(nil))
    }

    @Test func firstClearNeedsHalfASecondOfNewMeasurementsNotPolls() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        for tick in 10...20 {
            #expect(
                try clearCue(&policy, measuredAt: 1, now: Double(tick) / 10, maxResultAge: 2) == nil
            )
        }
        #expect(try clearCue(&policy, measuredAt: 2.1) == nil)
        #expect(try clearCue(&policy, measuredAt: 2.3) == nil)
        #expect(try clearCue(&policy, measuredAt: 2.5) == nil)
        #expect(try clearCue(&policy, measuredAt: 2.6) == .clear)
        #expect(try clearCue(&policy, measuredAt: 2.7) == nil)
        #expect(ObstacleRouteSpeech.clear.chinese == "前方畅通")
    }
    @Test func distantObstacleAnnouncesDistanceNotPreviewTurn() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let cue = policy.cue(
            update: try update("distantObstacle", distance: 3),
            heading: try heading(30),
            now: 1,
            deviationDegrees: 12
        )
        #expect(cue == .obstacle(3, nil))
        #expect(cue?.chinese == "有障碍")
    }
    @Test func nearObstacleCombinesDistanceAndCurrentTurn() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let cue = policy.cue(
            update: try update("nearObstacle"),
            heading: try heading(-25),
            now: 1,
            deviationDegrees: 12
        )
        #expect(cue == .obstacle(1.4, -1))
        #expect(cue?.chinese == "有障碍，向左")
        #expect(ObstacleRouteSpeech.obstacle(0.6, 1).chinese == "障碍很近，向右")
        #expect(
            policy.cue(
                update: try update("nearObstacle"),
                heading: try heading(-25),
                now: 1.1,
                deviationDegrees: 12
            ) == nil
        )
    }
    /// Returns whether the same turn is spoken again after the heading passed through 8°.
    private func turnRepeatsAfterEightDegrees(alignment: Float?) throws -> Bool {
        var policy = ObstacleRouteAnnouncementPolicy()
        let near = try update("nearObstacle")
        var cues: [ObstacleRouteSpeech] = []
        for tick in 10...45 {
            let angle: Float = (11...15).contains(tick) ? -8 : -25
            let now = Double(tick) / 10
            let cue =
                if let alignment {
                    policy.cue(
                        update: near,
                        heading: try heading(angle),
                        now: now,
                        deviationDegrees: 12,
                        alignmentDegrees: alignment
                    )
                } else {
                    policy.cue(
                        update: near,
                        heading: try heading(angle),
                        now: now,
                        deviationDegrees: 12
                    )
                }
            if let cue { cues.append(cue) }
        }
        #expect(cues.first == .obstacle(1.4, -1))
        return cues.count == 2 && cues[1] == .obstacle(1.4, -1)
    }

    @Test func turnSpeechUsesTheConfiguredAlignmentAngle() throws {
        // Vibration reports "aligned" at the configured angle; speech must re-arm at the same
        // one, or the two disagree about whether the user has turned far enough.
        #expect(try turnRepeatsAfterEightDegrees(alignment: 9))
        #expect(try !turnRepeatsAfterEightDegrees(alignment: 5))
        #expect(try !turnRepeatsAfterEightDegrees(alignment: nil))
    }

    @Test func previewChangesCannotTriggerAnotherTurn() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        var u = try update("nearObstacle")
        _ = policy.cue(update: u, heading: try heading(-25), now: 1, deviationDegrees: 12)
        u.waypointGuidance?.nextTarget = SIMD3(-3, 0, -2)
        u.waypointGuidance?.nextPreparedAt = 1.2
        #expect(
            policy.cue(update: u, heading: try heading(-25), now: 1.2, deviationDegrees: 12) == nil
        )
        // Promotion does not bypass the cooldown; the latest current direction is used later.
        #expect(
            policy.cue(
                update: try update("nearObstacle", goal: 11),
                heading: try heading(25),
                now: 1.3,
                deviationDegrees: 12
            ) == nil
        )
        #expect(
            policy.cue(
                update: try update("nearObstacle", goal: 11),
                heading: try heading(25),
                now: 3.5,
                deviationDegrees: 12
            ) == .obstacle(1.4, 1)
        )
    }
    @Test func unavailableHeadingCannotSpeakAPreviewDirection() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(
            policy.cue(
                update: try update("nearObstacle"),
                heading: nil,
                now: 1,
                deviationDegrees: 12
            ) == .obstacle(1.4, nil)
        )
        #expect(
            policy.cue(
                update: try update("nearObstacle"),
                heading: try heading(25),
                now: 1.1,
                deviationDegrees: 12
            ) == nil
        )
        #expect(
            policy.cue(
                update: try update("nearObstacle"),
                heading: try heading(25),
                now: 3.5,
                deviationDegrees: 12
            ) == .obstacle(1.4, 1)
        )
    }
    /// Distance is too noisy to speak; only crossing into "close" re-announces.
    @Test func onlyTheNearLevelChangeReannounces() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        _ = policy.cue(
            update: try update("distantObstacle", distance: 4),
            heading: nil,
            now: 1,
            deviationDegrees: 12
        )
        #expect(
            policy.cue(
                update: try update("distantObstacle", distance: 0.8),
                heading: nil,
                now: 3,
                deviationDegrees: 12
            ) == nil
        )
        #expect(
            policy.cue(
                update: try update("distantObstacle", distance: 2.5),
                heading: nil,
                now: 5,
                deviationDegrees: 12
            ) == nil
        )
        #expect(
            policy.cue(
                update: try update("distantObstacle", distance: 0.8),
                heading: nil,
                now: 5.5,
                deviationDegrees: 12
            ) == .obstacle(0.8, nil)
        )
        #expect(
            policy.cue(
                update: try update("distantObstacle", distance: 0.6),
                heading: nil,
                now: 9,
                deviationDegrees: 12
            ) == nil
        )
    }
    @Test func blockedAndRecoveryHaveDistinctCues() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let cue = policy.cue(
            update: try update("blocked"),
            heading: try heading(-40),
            now: 1,
            deviationDegrees: 12
        )
        #expect(cue == .blocked(1.4))
        #expect(cue?.chinese == "有障碍，无法绕行")
        for tick in 20...34 {
            #expect(try clearCue(&policy, measuredAt: Double(tick) / 10) == nil)
        }
        #expect(try clearCue(&policy, measuredAt: 3.5) == .clear)
    }

    @Test func retainedClearCannotStartANewAnnouncementAfterSuppression() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(try clearCue(&policy, measuredAt: 1) == nil)
        policy.pauseObservations()
        for tick in 15...25 {
            #expect(try clearCue(&policy, measuredAt: 1, now: Double(tick) / 10) == nil)
        }
        for tick in 26...30 {
            #expect(try clearCue(&policy, measuredAt: Double(tick) / 10) == nil)
        }
        #expect(try clearCue(&policy, measuredAt: 3.1) == .clear)
    }

    @Test func sameSessionResumeKeepsSpokenClearButANewEpochRequiresNewEvidence() throws {
        var session = WaypointFeedbackSession()
        _ = session.synchronize(epoch: 1, parameterVersion: 0, planningEnabled: true)
        for tick in 10...14 {
            #expect(try clearCue(&session.speech, measuredAt: Double(tick) / 10) == nil)
        }
        #expect(try clearCue(&session.speech, measuredAt: 1.5) == .clear)
        for _ in 1...10 {
            session.speech.pauseObservations()
            _ = session.synchronize(epoch: 1, parameterVersion: 0, planningEnabled: true)
        }
        #expect(try clearCue(&session.speech, measuredAt: 1.5, now: 5) == nil)
        for tick in 51...65 {
            #expect(try clearCue(&session.speech, measuredAt: Double(tick) / 10) == nil)
        }
        _ = session.synchronize(epoch: 2, parameterVersion: 0, planningEnabled: true)
        for tick in 70...74 {
            #expect(try clearCue(&session.speech, measuredAt: Double(tick) / 10) == nil)
        }
        #expect(try clearCue(&session.speech, measuredAt: 7.5) == .clear)
    }

    @Test func pauseBreaksPartialAlignmentWithoutRepeatingTheSpokenTurn() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let near = try update("nearObstacle")
        var spoken: [ObstacleRouteSpeech] = []
        for tick in 10...40 {
            if tick == 33 {
                policy.pauseObservations()
                continue
            }
            let angle: Float = (30...34).contains(tick) ? 0 : -25
            if let cue = policy.cue(
                update: near,
                heading: try heading(angle),
                now: Double(tick) / 10,
                deviationDegrees: 12
            ) {
                spoken.append(cue)
            }
        }
        #expect(spoken == [.obstacle(1.4, -1)])
    }

    @Test func delayedClearMeasurementsCannotCompleteConfirmation() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        for tick in 10...20 {
            let measured = Double(tick) / 10
            #expect(try clearCue(&policy, measuredAt: measured, now: measured + 0.3) == nil)
        }
    }

    @Test func confirmedObstaclePreemptsClearAndDoesNotRepeat() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let near = try update("nearObstacle")
        for tick in 10...14 {
            #expect(try clearCue(&policy, measuredAt: Double(tick) / 10) == nil)
        }
        #expect(try clearCue(&policy, measuredAt: 1.5) == .clear)
        let preemptsClear = policy.interruptIfObsolete(update: near, heading: nil, threshold: 12)
        #expect(preemptsClear)
        #expect(
            policy.cue(update: near, heading: nil, now: 1.6, deviationDegrees: 12)
                == .obstacle(1.4, nil)
        )
        let interruptsAgain = policy.interruptIfObsolete(update: near, heading: nil, threshold: 12)
        #expect(!interruptsAgain)
        #expect(policy.cue(update: near, heading: nil, now: 1.7, deviationDegrees: 12) == nil)
    }

    @Test func suppressedStartupDoesNotQueueAnObsoleteObstacle() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(
            policy.cue(
                update: try update("nearObstacle"),
                heading: try heading(-25),
                now: 1,
                deviationDegrees: 12,
                canSpeak: false
            ) == nil
        )
        let blocked = try update("blocked")
        #expect(
            policy.cue(update: blocked, heading: nil, now: 1.1, deviationDegrees: 12)
                == .blocked(1.4)
        )
    }

    @Test func missingWaypointStateDoesNotStartClearWait() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(policy.cue(update: .init(), heading: nil, now: 1, deviationDegrees: 12) == nil)
        for tick in 40...44 {
            #expect(try clearCue(&policy, measuredAt: Double(tick) / 10) == nil)
        }
        #expect(try clearCue(&policy, measuredAt: 4.5) == .clear)
    }

    @Test func firstFrameObstacleIsConfirmedBeforeTheFirstSceneCue() {
        var predictor = PathPredictor(policy: .obstacleVeto)
        var policy = ObstacleRouteAnnouncementPolicy()
        let parameters = ProbeParameters()
        let pose = RigidPose(position: V3(0, 1.4, 0))
        let plane = GroundPlane(normal: V3(0, 1, 0), offset: 0, floorPriorConfirmed: true)
        var announcedObstacle = false
        for index in 0...5 {
            let time = 1 + Double(index) / 10
            let id = UInt64(index + 1)
            var grid = LocalGrid(
                basis: GroundBasis(plane: plane, pose: pose)!,
                parameters: parameters,
                timestamp: time,
                frameID: id,
                epoch: 1
            )
            for cell in grid.cells.indices {
                let center = grid.center(cell)
                let obstacle = abs(center.x) < 0.1 && center.y > 0.8 && center.y < 1
                grid.cells[cell].state = obstacle ? .obstacle : .unknown
                grid.cells[cell].obstacleSamples = obstacle ? 6 : 0
            }
            var input = AnalysisResult(
                epoch: 1,
                frameID: id,
                timestamp: time,
                parameters: parameters,
                status: "synthetic",
                source: "synthetic"
            )
            input.grid = grid
            input.plane = plane
            input.sourcePose = pose
            input.sourceDirectionStable = true
            let update = predictor.update(result: input, observation: nil, options: .init())
            let cue = policy.cue(update: update, heading: nil, now: time, deviationDegrees: 12)
            if index == 0 {
                #expect((update.occupancyFilter?.pendingCells ?? 0) > 0)
                #expect(cue == nil)
            } else if !announcedObstacle, update.waypointGuidance?.scenario == .nearObstacle {
                announcedObstacle = true
                #expect(cue == .obstacle(update.waypointGuidance?.obstacleDistance, nil))
            } else {
                #expect(cue == nil)
            }
            if index == 3 {
                #expect((update.occupancyFilter?.confirmedCells ?? 0) > 0)
                #expect(update.waypointGuidance?.scenario == .nearObstacle)
            }
        }
        #expect(announcedObstacle)
    }

    @Test func offscreenGoalFailureRequestsCameraAdjustment() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        var u = try update("blocked")
        u.reason = "no_visible_target"
        let cue = policy.cue(update: u, heading: nil, now: 1, deviationDegrees: 12)
        #expect(cue == .adjustCamera(1.4))
        #expect(cue?.chinese == "有障碍，转动手机")
    }
}

extension ObstacleRouteSpeechTests {
    @Test func RepeatedGoalIDsOnSameSideDoNotRearmSpeech() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        _ = policy.cue(
            update: try update("nearObstacle"),
            heading: try heading(-25),
            now: 1,
            deviationDegrees: 12
        )
        for i in 1...40 {
            let u = try update("nearObstacle", goal: UInt64(10 + i))
            #expect(
                !policy.interruptIfObsolete(update: u, heading: try heading(-25), threshold: 12)
            )
            #expect(
                policy.cue(
                    update: u,
                    heading: try heading(-25),
                    now: 1 + Double(i) * 0.1,
                    deviationDegrees: 12
                ) == nil
            )
        }
    }
    @Test func transientScenarioChangesDoNotRestartAudio() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        _ = policy.cue(
            update: try update("nearObstacle"),
            heading: try heading(-25),
            now: 1,
            deviationDegrees: 12
        )
        for i in 1...30 {
            let scenario = i.isMultiple(of: 2) ? "nearObstacle" : "clear"
            #expect(
                policy.cue(
                    update: try update(scenario),
                    heading: try heading(-25),
                    now: 1 + Double(i) * 0.1,
                    deviationDegrees: 12
                ) == nil
            )
        }
    }
    @Test func obsoleteTurnCancelsButDoesNotResetCooldownOrQueueOldDirection() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let old = try update("nearObstacle")
        _ = policy.cue(update: old, heading: try heading(-25), now: 1, deviationDegrees: 12)
        let next = try update("nearObstacle", goal: 11)
        #expect(policy.interruptIfObsolete(update: next, heading: try heading(25), threshold: 12))
        #expect(
            policy.cue(update: next, heading: try heading(25), now: 1.1, deviationDegrees: 12)
                == nil
        )
        // Back to the original side before the cooldown expires: no queued right instruction.
        #expect(
            policy.cue(update: next, heading: try heading(-25), now: 3.5, deviationDegrees: 12)
                == nil
        )
    }
    @Test func audioBusyDoesNotConsumeAnUnspokenTurn() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let u = try update("nearObstacle")
        #expect(
            policy.cue(
                update: u,
                heading: try heading(-25),
                now: 1,
                deviationDegrees: 12,
                canSpeak: false
            ) == nil
        )
        #expect(
            policy.cue(update: u, heading: try heading(25), now: 2, deviationDegrees: 12)
                == .obstacle(1.4, 1)
        )
    }
}
