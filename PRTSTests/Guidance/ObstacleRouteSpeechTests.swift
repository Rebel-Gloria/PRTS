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

    /// Existing scene-transition cases start after the separately tested startup interval.
    private func initializedPolicy() throws -> ObstacleRouteAnnouncementPolicy {
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(
            policy.cue(update: try update("clear"), heading: nil, now: 0, deviationDegrees: 12)
                == .initializing
        )
        return policy
    }

    @Test func openSpaceSpeaksOnceAfterInitializationWithoutAPath() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let u = try update("clear")
        #expect(policy.cue(update: u, heading: nil, now: 1, deviationDegrees: 12) == .initializing)
        #expect(policy.cue(update: u, heading: nil, now: 1.49, deviationDegrees: 12) == nil)
        #expect(policy.cue(update: u, heading: nil, now: 1.5, deviationDegrees: 12) == .clear)
        #expect(policy.cue(update: u, heading: nil, now: 10, deviationDegrees: 12) == nil)
        #expect(ObstacleRouteSpeech.initializing.chinese == "初始化中")
        #expect(ObstacleRouteSpeech.initializing.english == "Initializing")
        #expect(ObstacleRouteSpeech.clear.chinese == "前方畅通")
    }
    @Test func distantObstacleAnnouncesDistanceNotPreviewTurn() throws {
        var policy = try initializedPolicy()
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
        var policy = try initializedPolicy()
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
        var policy = try initializedPolicy()
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
        var policy = try initializedPolicy()
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
        var policy = try initializedPolicy()
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
        var policy = try initializedPolicy()
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
        var policy = try initializedPolicy()
        let cue = policy.cue(
            update: try update("blocked"),
            heading: try heading(-40),
            now: 1,
            deviationDegrees: 12
        )
        #expect(cue == .blocked(1.4))
        #expect(cue?.chinese == "有障碍，无法绕行")
        #expect(
            policy.cue(update: try update("clear"), heading: nil, now: 2, deviationDegrees: 12)
                == nil
        )
        #expect(
            policy.cue(update: try update("clear"), heading: nil, now: 3.5, deviationDegrees: 12)
                == .clear
        )
    }
    @Test func resetWaitsSilentlyBeforeSceneFeedback() throws {
        var policy = try initializedPolicy()
        let u = try update("clear")
        _ = policy.cue(update: u, heading: nil, now: 1, deviationDegrees: 12)
        policy.reset()
        #expect(policy.cue(update: u, heading: nil, now: 2, deviationDegrees: 12) == nil)
        #expect(policy.cue(update: u, heading: nil, now: 2.49, deviationDegrees: 12) == nil)
        #expect(policy.cue(update: u, heading: nil, now: 2.5, deviationDegrees: 12) == .clear)
    }

    @Test func startingGuidanceAnnouncesInitializationAgain() throws {
        var policy = try initializedPolicy()
        let u = try update("clear")
        policy.reset()
        policy.announceInitialization()
        #expect(policy.cue(update: u, heading: nil, now: 2, deviationDegrees: 12) == .initializing)
        #expect(policy.cue(update: u, heading: nil, now: 2.5, deviationDegrees: 12) == .clear)
    }
}

extension ObstacleRouteSpeechTests {
    @Test func initializationUsesTheLatestSceneWithoutSpendingItsCooldown() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(
            policy.cue(update: try update("clear"), heading: nil, now: 1, deviationDegrees: 12)
                == .initializing
        )
        #expect(
            policy.cue(
                update: try update("nearObstacle"),
                heading: try heading(-25),
                now: 1.3,
                deviationDegrees: 12
            ) == nil
        )
        #expect(
            policy.cue(update: try update("blocked"), heading: nil, now: 1.49, deviationDegrees: 12)
                == nil
        )
        #expect(
            policy.cue(update: try update("blocked"), heading: nil, now: 1.5, deviationDegrees: 12)
                == .blocked(1.4)
        )
        #expect(
            policy.cue(update: try update("clear"), heading: nil, now: 1.6, deviationDegrees: 12)
                == nil
        )
        #expect(
            policy.cue(update: try update("clear"), heading: nil, now: 4, deviationDegrees: 12)
                == .clear
        )
    }

    @Test func busyAudioDoesNotConsumeInitializationOrQueueAStartupDirection() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        let u = try update("nearObstacle")
        #expect(
            policy.cue(update: u, heading: nil, now: 1, deviationDegrees: 12, canSpeak: false)
                == nil
        )
        #expect(policy.cue(update: u, heading: nil, now: 2, deviationDegrees: 12) == .initializing)
        #expect(
            policy.cue(update: u, heading: try heading(-25), now: 2.3, deviationDegrees: 12)
                == nil
        )
        #expect(
            policy.cue(
                update: u,
                heading: try heading(-25),
                now: 2.5,
                deviationDegrees: 12,
                canSpeak: false
            ) == nil
        )
        #expect(
            policy.cue(update: u, heading: try heading(25), now: 3, deviationDegrees: 12)
                == .obstacle(1.4, 1)
        )
    }

    @Test func missingWaypointStateDoesNotStartInitialization() throws {
        var policy = ObstacleRouteAnnouncementPolicy()
        #expect(policy.cue(update: .init(), heading: nil, now: 1, deviationDegrees: 12) == nil)
        let u = try update("clear")
        #expect(policy.cue(update: u, heading: nil, now: 4, deviationDegrees: 12) == .initializing)
        #expect(policy.cue(update: u, heading: nil, now: 4.49, deviationDegrees: 12) == nil)
        #expect(policy.cue(update: u, heading: nil, now: 4.5, deviationDegrees: 12) == .clear)
    }

    @Test func firstFrameObstacleIsConfirmedBeforeTheFirstSceneCue() {
        var predictor = PathPredictor(policy: .obstacleVeto)
        var policy = ObstacleRouteAnnouncementPolicy()
        let parameters = ProbeParameters()
        let pose = RigidPose(position: V3(0, 1.4, 0))
        let plane = GroundPlane(normal: V3(0, 1, 0), offset: 0, floorPriorConfirmed: true)
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
                #expect(cue == .initializing)
            } else if index == 5 {
                #expect(update.waypointGuidance?.scenario == .nearObstacle)
                #expect(cue == .obstacle(update.waypointGuidance?.obstacleDistance, nil))
            } else {
                #expect(cue == nil)
            }
            if index == 3 {
                #expect((update.occupancyFilter?.confirmedCells ?? 0) > 0)
                #expect(update.waypointGuidance?.scenario == .nearObstacle)
            }
        }
    }

    @Test func offscreenGoalFailureRequestsCameraAdjustment() throws {
        var policy = try initializedPolicy()
        var u = try update("blocked")
        u.reason = "no_visible_target"
        let cue = policy.cue(update: u, heading: nil, now: 1, deviationDegrees: 12)
        #expect(cue == .adjustCamera(1.4))
        #expect(cue?.chinese == "有障碍，转动手机")
    }
}

extension ObstacleRouteSpeechTests {
    @Test func RepeatedGoalIDsOnSameSideDoNotRearmSpeech() throws {
        var policy = try initializedPolicy()
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
        var policy = try initializedPolicy()
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
        var policy = try initializedPolicy()
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
        var policy = try initializedPolicy()
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
