import XCTest
import simd
@testable import SpatialCore

/// Synthetic metre-scale scenes and timestamps; no live-sensor acceptance is implied.
extension ForwardRouteTests {
    func testWaypointOpenSceneHasNoDrawnRoute() {
        var predictor = PathPredictor()
        let update = predictor.update(result: frame(cells: { _ in .unknown }), observation: nil, options: .init())
        XCTAssertNil(update.path)
        XCTAssertNil(update.goal)
        XCTAssertNil(update.projection)
        XCTAssertEqual(update.reason, "front_clear")
    }

    func testWaypointFarObstacleStopsAtLeastHalfMetreBeforeIt() throws {
        var predictor = PathPredictor()
        var update = PathUpdate()
        for i in 0...4 {
            update = predictor.update(result: frame(UInt64(i+1), 1+Double(i)*0.1, cells: {
                abs($0.x) < 0.2 && -$0.z > 2.9 && -$0.z < 3.2 ? .obstacle : .unknown
            }), observation: nil, options: .init())
        }
        let target = try XCTUnwrap(update.goal?.point)
        XCTAssertEqual(target.x, 0, accuracy: 0.06)
        XCTAssertLessThanOrEqual(-target.z, 2.4)
        XCTAssertGreaterThan(-target.z, 2)
        XCTAssertEqual(update.path?.points.last, target)
    }
}

extension ForwardRouteTests {
    /// Direct confirmed model input isolates target scheduling from the separately tested 300ms filter.
    private func waypointModel(_ id: UInt64 = 1, _ time: Double = 1,
                               pose: RigidPose = .init(position: V3(0,1.4,0)),
                               cells: (V3) -> CellState) -> AnalysisResult {
        var value = frame(id, time, pose: pose, cells: cells)
        for index in value.grid!.cells.indices where value.grid!.cells[index].state != .obstacle {
            value.grid!.cells[index].state = .candidate
        }
        return value
    }

    func testWaypointNearObstacleProducesCheckedBendAndMutablePreview() throws {
        var planner = ObstacleWaypointPlanner()
        let r = waypointModel(cells: box)
        let first = planner.update(result:r, cameraResult:nil, options:.init(), view:nil)
        let path = try XCTUnwrap(first.path)
        let goal = try XCTUnwrap(first.goal)
        XCTAssertEqual(first.waypointGuidance?.scenario,.nearObstacle)
        XCTAssertGreaterThan(abs(goal.point.x),0.25)
        XCTAssertEqual(path.points.last,goal.point)
        XCTAssertTrue(try XCTUnwrap(RoutePlanningGrid(result:r,obstacleVeto:true)).supports(path.points))
        XCTAssertNotNil(first.waypointGuidance?.nextTarget)
        XCTAssertFalse(path.points.contains(first.waypointGuidance!.nextTarget!))
        let second = planner.update(result:waypointModel(2,1.1,cells:box),cameraResult:nil,options:.init(),view:nil)
        XCTAssertEqual(second.goal?.id,goal.id)
        XCTAssertEqual(second.goal?.point,goal.point)
    }

    func testWaypointArrivalAtomicallyPromotesNextWithoutEmptyFrame() throws {
        var planner = ObstacleWaypointPlanner()
        let first = planner.update(result:waypointModel(cells:box),cameraResult:nil,options:.init(),view:nil)
        let goal = try XCTUnwrap(first.goal)
        let next = try XCTUnwrap(first.waypointGuidance?.nextTarget)
        // Remain beyond arrival tolerance: even a prepared next target is not drawn.
        let midway = goal.point * 0.25 + V3(0,1.4,0)
        let pending = planner.update(result:waypointModel(2,1.1,pose:.init(position:midway),cells:box),cameraResult:nil,options:.init(),view:nil)
        XCTAssertEqual(pending.goal?.id,goal.id)
        let reached = planner.update(result:waypointModel(3,1.2,pose:.init(position:goal.point+V3(0,1.4,0)),cells:box),cameraResult:nil,options:.init(),view:nil)
        XCTAssertNotNil(reached.path)
        XCTAssertNotEqual(reached.goal?.id,goal.id)
        XCTAssertEqual(reached.goal?.point,next)
        XCTAssertEqual(reached.path?.points.last,reached.goal?.point)
        XCTAssertEqual(reached.goalChangeReason,"current_target_reached")
    }

    func testWaypointPreviewObstacleChangesOnlyUncommittedSuffix() throws {
        var planner = ObstacleWaypointPlanner()
        let first = planner.update(result:waypointModel(cells:box),cameraResult:nil,options:.init(),view:nil)
        let target = try XCTUnwrap(first.waypointGuidance?.nextTarget)
        let changed = planner.update(result:waypointModel(2,1.35,cells:{
            self.box($0) == .obstacle || simd_distance($0,target) < 0.16 ? .obstacle : .unknown
        }),cameraResult:nil,options:.init(),view:nil)
        XCTAssertEqual(changed.goal?.id,first.goal?.id)
        XCTAssertEqual(changed.goal?.point,first.goal?.point)
        if let next = changed.waypointGuidance?.nextTarget { XCTAssertGreaterThan(simd_distance(next,target),0.1) }
    }

    func testWaypointConfirmedCurrentTargetBlockReplans() throws {
        var planner = ObstacleWaypointPlanner()
        let first = planner.update(result:waypointModel(cells:box),cameraResult:nil,options:.init(),view:nil)
        let point = try XCTUnwrap(first.goal?.point)
        let r = waypointModel(2,1.1,cells: { self.box($0) == .obstacle || simd_distance($0,point) < 0.16 ? .obstacle : .unknown })
        let update = planner.update(result:r,cameraResult:nil,options:.init(),view:nil)
        XCTAssertEqual(update.goalChangeReason,"target_or_path_blocked")
        XCTAssertNotEqual(update.goal?.point,point)
        if let path = update.path { XCTAssertTrue(RoutePlanningGrid(result:r,obstacleVeto:true)!.supports(path.points)) }
    }

    func testWaypointFullWidthObstacleHasExplicitBlockedState() {
        var planner = ObstacleWaypointPlanner()
        let update = planner.update(result:waypointModel(cells:{ _ in .obstacle }),cameraResult:nil,options:.init(),view:nil)
        XCTAssertNil(update.path)
        XCTAssertNil(update.goal)
        XCTAssertEqual(update.waypointGuidance?.scenario,.blocked)
    }

    func testWaypointDisappearingObstacleClearsLineAndPreview() throws {
        var planner = ObstacleWaypointPlanner()
        XCTAssertNotNil(planner.update(result:waypointModel(cells:box),cameraResult:nil,options:.init(),view:nil).path)
        let empty = planner.update(result:waypointModel(2,1.1,cells:{ _ in .unknown }),cameraResult:nil,options:.init(),view:nil)
        XCTAssertNil(empty.path);XCTAssertNil(empty.goal);XCTAssertNil(empty.waypointGuidance?.nextTarget)
        XCTAssertEqual(empty.waypointGuidance?.scenario,.clear)
    }

    func testWaypointStationaryTurnRequiresThreeSecondsAndNoTranslation() {
        var dwell = StationaryRouteTurn(), options = PathOptions()
        options.userTurnSeconds = 3
        for i in 0...29 {
            XCTAssertFalse(dwell.update(foot:.zero,forward:V3(1,0,0),routeForward:V3(0,0,-1),now:Double(i)*0.1,options:options))
        }
        XCTAssertTrue(dwell.update(foot:.zero,forward:V3(1,0,0),routeForward:V3(0,0,-1),now:3,options:options))
        dwell.reset()
        for i in 0...50 {
            XCTAssertFalse(dwell.update(foot:V3(Float(i)*0.03,0,0),forward:V3(1,0,0),routeForward:V3(0,0,-1),now:Double(i)*0.1,options:options))
        }
    }

    func testWaypointStationaryTurnActuallyAdoptsCameraDirection() throws {
        var planner = ObstacleWaypointPlanner()
        let far: (V3)->CellState = { abs($0.x)<0.2 && -$0.z>2.9 && -$0.z<3.2 ? .obstacle : .unknown }
        _ = planner.update(result:waypointModel(cells:far),cameraResult:nil,options:.init(),view:nil)
        var last = PathUpdate()
        for i in 0...30 {
            let original = waypointModel(UInt64(i+2),1.1+Double(i)*0.1,cells:far)
            var lane = original; lane.sourcePose = pose(yaw:-90)
            let turned = waypointModel(UInt64(i+2),1.1+Double(i)*0.1,pose:pose(yaw:-90),cells:far)
            last = planner.update(result:lane,cameraResult:turned,options:.init(),view:nil)
        }
        XCTAssertEqual(last.goalChangeReason,"stationary_heading_changed")
        XCTAssertGreaterThan(last.waypointGuidance?.referenceForward.x ?? 0,0.9)
        XCTAssertNil(last.path)
    }

    func testWaypointFrameExitTriggersImmediateNewDirectionQuery() throws {
        var planner = ObstacleWaypointPlanner()
        let view = RouteCameraView(intrinsics:.init(fx:200,fy:200,cx:320,cy:240,width:640,height:480))
        let r = waypointModel(cells:box)
        _ = planner.update(result:r,cameraResult:nil,options:.init(),view:nil)
        var turned = waypointModel(2,1.1,cells:box); turned.sourcePose = pose(yaw:-90)
        let camera = waypointModel(2,1.1,pose:pose(yaw:-90),cells:box)
        let update = planner.update(result:turned,cameraResult:camera,options:.init(),view:view)
        XCTAssertEqual(update.goalChangeReason,"target_out_of_view")
        XCTAssertGreaterThan(update.waypointGuidance?.referenceForward.x ?? 0,0.9)
    }

    func testWaypointProjectionUsesImageIntrinsicsAndRejectsBehindCamera() {
        let view = RouteCameraView(intrinsics:.init(fx:100,fy:100,cx:49.5,cy:49.5,width:100,height:100))
        XCTAssertTrue(view.contains(V3(0,0,-2),pose:.init()))
        XCTAssertFalse(view.contains(V3(0,0,2),pose:.init()))
        XCTAssertFalse(view.contains(V3(2,0,-2),pose:.init()))
        XCTAssertFalse(view.contains(V3(0,-2,-2),pose:.init()))
    }

    func testWaypointApproachRemainsFixedUntilNearStageAndIgnoresFloorNoise() throws {
        var predictor = PathPredictor(), original = PathUpdate()
        let obstacle: (V3)->CellState = { abs($0.x)<0.2 && -$0.z>2.9 && -$0.z<3.2 ? .obstacle : .unknown }
        for i in 0...4 { original = predictor.update(result:frame(UInt64(i+1),1+Double(i)*0.1,cells:obstacle),observation:nil,options:.init()) }
        let goal = try XCTUnwrap(original.goal)
        for i in 5...10 {
            var r = frame(UInt64(i+1),1+Double(i)*0.1,pose:.init(position:V3(0,1.4,-0.3)),cells:obstacle)
            r.plane?.offset = 0.03
            let u = predictor.update(result:r,observation:nil,options:.init())
            XCTAssertEqual(u.goal?.point,goal.point);XCTAssertEqual(u.goal?.id,goal.id)
        }
        let near = predictor.update(result:frame(12,2.1,pose:.init(position:V3(0,1.4,-1.2)),cells:obstacle),observation:nil,options:.init())
        XCTAssertEqual(near.waypointGuidance?.scenario,.nearObstacle)
        XCTAssertNotNil(near.path)
        XCTAssertNotEqual(near.goal?.id,goal.id)
    }

    func testWaypointOpenUpdateAtomicallyRemovesOldRouteAndRejectsLateFrame() throws {
        var predictor = PathPredictor(), before = PathUpdate()
        for i in 0...3 { before = predictor.update(result:frame(UInt64(i+1),1+Double(i)*0.1,cells:box),observation:nil,options:.init()) }
        XCTAssertNotNil(before.path)
        let clear = predictor.update(result:frame(5,1.4,cells:{ _ in .unknown }),observation:nil,options:.init())
        var gate = ResultPresentationGate();gate.enabled = true;gate.trackingNormal = true
        gate.epoch = 1;gate.frameID = 5;gate.frameTimestamp = 1.4
        let commit = RoutePublicationPolicy.decide(current:before,candidate:clear,gate:gate,hazardWatermark:0,now:1.4,expectedPolicy:.obstacleVeto)
        XCTAssertTrue(commit.accepted);XCTAssertNil(commit.update.path)
        XCTAssertEqual(commit.update.continuity?.status,.clear)
        let late = RoutePublicationPolicy.decide(current:clear,candidate:before,gate:gate,hazardWatermark:0,now:1.4,expectedPolicy:.obstacleVeto)
        XCTAssertFalse(late.accepted);XCTAssertNil(late.update.path)
    }

    func testWaypointEpochResetDropsCurrentAndDraft() throws {
        var predictor = PathPredictor(), old = PathUpdate()
        for i in 0...3 { old = predictor.update(result:frame(UInt64(i+1),1+Double(i)*0.1,cells:box),observation:nil,options:.init()) }
        XCTAssertNotNil(old.path)
        var r = frame(1,3,cells:{ _ in .unknown });r.epoch = 2;r.grid?.epoch = 2
        let reset = predictor.update(result:r,observation:nil,options:.init())
        XCTAssertNil(reset.path);XCTAssertNil(reset.goal);XCTAssertNil(reset.waypointGuidance?.nextTarget)
        XCTAssertEqual(reset.continuity?.epoch,2)
    }

    func testWaypointOptionsDecodeOldSettingsAndEnforceRequestedStandOff() throws {
        let old = try JSONDecoder().decode(PathOptions.self,from:Data("{}".utf8))
        XCTAssertEqual(old.waypoints.nearDistance,2)
        var changed = old;changed.waypoints.standOff = 0.1
        XCTAssertEqual(changed.validated().waypoints.standOff,0.5)
        XCTAssertEqual(try JSONDecoder().decode(PathOptions.self,from:JSONEncoder().encode(changed)),changed)
    }
}

extension ForwardRouteTests {
    func testWaypointConnectedSideWallDoesNotShortenFrontDistance() throws {
        var planner = ObstacleWaypointPlanner()
        let r = waypointModel(cells:{ p in
            let across = p.x > -0.15 && p.x < 1.15 && -p.z > 2.9 && -p.z < 3.15
            let side = p.x > 0.9 && p.x < 1.15 && -p.z > 0.9 && -p.z < 3.15
            return across || side ? .obstacle : .unknown
        })
        let u = planner.update(result:r,cameraResult:nil,options:.init(),view:nil)
        XCTAssertEqual(u.waypointGuidance?.scenario,.distantObstacle)
        XCTAssertGreaterThan(u.waypointGuidance?.obstacleDistance ?? 0,2.7)
        let target = try XCTUnwrap(u.goal?.point)
        XCTAssertTrue(ObstacleWaypointSearch.hasStandOff(target,raster:RoutePlanningGrid(result:r,obstacleVeto:true)!,distance:0.5))
    }

    func testWaypointPendingGhostStaysClearAndConfirmedObstacleStartsBypass() {
        var planner = PathPredictor()
        for i in 0...3 {
            let u = planner.update(result:frame(UInt64(i+1),1+Double(i)*0.1,cells:box),observation:nil,options:.init())
            if i<3 { XCTAssertEqual(u.waypointGuidance?.scenario,.clear);XCTAssertNil(u.path) }
            else { XCTAssertEqual(u.waypointGuidance?.scenario,.nearObstacle);XCTAssertNotNil(u.path) }
        }
        let clear = planner.update(result:frame(5,1.4,cells:{ _ in .unknown }),observation:nil,options:.init())
        XCTAssertEqual(clear.waypointGuidance?.scenario,.clear)
        XCTAssertNil(clear.path)
    }

    func testWaypointNoGroundDoesNotPreventClearDecision() {
        var planner = PathPredictor()
        var r = frame(cells:{ _ in .unknown });r.plane = nil;r.grid = nil
        let u = planner.update(result:r,observation:nil,options:.init())
        XCTAssertEqual(u.waypointGuidance?.scenario,.clear)
        XCTAssertEqual(u.continuity?.status,.clear)
        XCTAssertNil(u.path)
    }
}

extension ForwardRouteTests {
    func testWaypointOutOfImageReplacementCannotSelectAnotherInvisibleTarget() {
        let view = RouteCameraView(intrinsics:.init(fx:100,fy:100,cx:49.5,cy:49.5,width:100,height:100))
        XCTAssertNil(ObstacleWaypointSearch.targetIndex(in:[.zero,V3(0,0,2)],pose:.init(),view:view))
        XCTAssertEqual(ObstacleWaypointSearch.targetIndex(in:[.zero,V3(0,0,2)],pose:.init(),view:nil),1)
    }
}

extension ForwardRouteTests {
    func testWaypointNearCornerDoesNotReannounceTheSameGoalEveryFrame() throws {
        var planner = ObstacleWaypointPlanner()
        let first = planner.update(result:waypointModel(cells:box),cameraResult:nil,options:.init(),view:nil)
        let goal = try XCTUnwrap(first.goal)
        let foot = goal.point - simd_normalize(goal.point) * 0.2
        var settledGoalID: UInt64?
        for i in 2...8 {
            let update = planner.update(result:waypointModel(UInt64(i),1+Double(i)*0.1,
                pose:.init(position:foot+V3(0,1.4,0)),cells:box),cameraResult:nil,options:.init(),view:nil)
            let next = try XCTUnwrap(update.goal)
            if let settledGoalID {
                XCTAssertEqual(next.id,settledGoalID,"Standing near a corner must not repeatedly mint turn episodes")
            } else { settledGoalID = next.id }
            XCTAssertNotNil(update.path)

        }
    }
}
