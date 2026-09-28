import XCTest
import simd
@testable import SpatialCore

// Reuse synthetic fixture helpers. None of these tests are physical sensor evidence.
extension PathPredictionTests {
    func yawPose(_ degrees: Float) -> RigidPose {
        let t = degrees*Float.pi/180
        return .init(right:V3(cos(t),0,-sin(t)),up:V3(0,1,0),back:V3(sin(t),0,cos(t)),position:V3(0,1.4,0))
    }
    func testFixedTargetDoesNotMoveWhenFartherAreaAppears() {
        var tracker = PathPredictor()
        let a = tracker.update(result:result(hole:{_,z in z > 27}),observation:nil,options:.init())
        let b = tracker.update(result:result(id:2,time:1.1),observation:nil,options:.init())
        XCTAssertNotNil(a.goal);XCTAssertEqual(a.goal?.point,b.goal?.point);XCTAssertEqual(a.goal?.id,b.goal?.id)
        XCTAssertEqual(b.path?.points.last,a.goal?.point)
        XCTAssertGreaterThan(BluePathGrid(result:result())!.search().targetDistance!,a.targetGroundDistance!+0.5)
    }
    func testExpiredEvidenceKeepsGoalAndReacquiresSameWorldPoint() {
        var tracker = PathPredictor()
        let a = tracker.update(result:result(hole:{_,z in z > 27}),observation:nil,options:.init())
        let b = tracker.update(result:missing(id:2,time:4),observation:nil,options:.init())
        XCTAssertNil(b.path);XCTAssertEqual(b.goal?.point,a.goal?.point);XCTAssertEqual(b.reason,"fixed_goal_waiting_evidence")
        let c = tracker.update(result:result(id:3,time:4.1),observation:nil,options:.init())
        XCTAssertNotNil(c.path);XCTAssertEqual(c.goal?.id,a.goal?.id);XCTAssertEqual(c.path?.points.last,a.goal?.point)
        XCTAssertEqual(c.path?.observedAt,4.1)
    }
    func testArrivalReleasesGoalUsingGroundDistanceNotCameraHeight() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init())
        var r = missing(id:2,time:1.1);r.sourcePose!.position = a.goal!.point+V3(0,1.4,0)
        let b = tracker.update(result:r,observation:nil,options:.init())
        XCTAssertNil(b.goal);XCTAssertNil(b.path);XCTAssertEqual(b.goalChangeReason,"target_reached")
    }
    func testRangeExitHasDwellButStopsPresentationImmediately() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init())
        var r = missing(id:2,time:1.1);r.sourcePose = yawPose(100)
        let b = tracker.update(result:r,observation:nil,options:.init());XCTAssertEqual(b.goal?.id,a.goal?.id)
        XCTAssertNil(PathPresentation.make(path:a.path!,gate:gate(),pose:r.sourcePose!,options:.init(),now:1.1))
        r.frameID = 3;r.timestamp = 1.5
        let c = tracker.update(result:r,observation:nil,options:.init())
        XCTAssertNil(c.goal);XCTAssertEqual(c.goalChangeReason,"target_out_of_range")
    }
    func testFanBoundaryNoiseDoesNotChangeGoal() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init())
        let bearing = a.targetBearingDegrees!
        for (n,angle) in [Float(49),51,49,51,49].enumerated() {
            var r = missing(id:UInt64(n+2),time:1.1+Double(n)*0.1);r.sourcePose = yawPose(angle-bearing)
            let u = tracker.update(result:r,observation:nil,options:.init())
            XCTAssertEqual(u.goal?.id,a.goal?.id)
        }
    }
    func testRadialRangeExitReleasesEvenWhenHeadingIsVertical() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init())
        var r = missing(id:2,time:1.1)
        r.sourcePose = .init(right:V3(1,0,0),up:V3(0,0,-1),back:V3(0,1,0),position:V3(0,1.4,5))
        XCTAssertEqual(tracker.update(result:r,observation:nil,options:.init()).goal?.id,a.goal?.id)
        r.frameID = 3;r.timestamp = 1.5
        XCTAssertEqual(tracker.update(result:r,observation:nil,options:.init()).goalChangeReason,"target_out_of_range")
    }
    func testNewObstacleReRoutesToExactlySameGoalWhenPossible() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init()),points = a.path!.points
        let middle = points[0]+(points.last!-points[0])*0.5
        var r = result(id:2,time:1.1);let q = r.grid!.basis.local(middle),i = r.grid!.index(x:q.x,z:q.z)!
        r.grid!.cells[i].state = .obstacle;r.grid!.cells[i].obstacleSamples = 6
        let b = tracker.update(result:r,observation:nil,options:.init())
        XCTAssertEqual(b.reason,"replanned_around_obstacle");XCTAssertEqual(b.goal?.id,a.goal?.id)
        XCTAssertEqual(b.path?.points.last,a.goal?.point);XCTAssertTrue(BluePathGrid(result:r)!.supports(b.path!.points))
    }
    func testBlockedRouteWithoutNewGroundKeepsGoalButWithdrawsCue() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init())
        let points = a.path!.points,middle = points[0]+(points.last!-points[0])*0.5
        var r = result(id:2,time:1.1);let q = r.grid!.basis.local(middle),i = r.grid!.index(x:q.x,z:q.z)!
        r.grid!.cells[i].state = .obstacle;r.grid!.cells[i].obstacleSamples = 6;r.surfaceModel = nil
        let b = tracker.update(result:r,observation:nil,options:.init())
        XCTAssertNil(b.path);XCTAssertEqual(b.goal?.id,a.goal?.id);XCTAssertEqual(b.reason,"current_obstacle_invalidated")
        let c = tracker.update(result:result(id:3,time:1.2),observation:nil,options:.init())
        XCTAssertEqual(c.path?.points.last,a.goal?.point);XCTAssertEqual(c.goal?.id,a.goal?.id)
    }
    func testBlockedGoalCanBeRevokedAndNeverContinuesOldCue() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init())
        var r = result(id:2,time:1.1);let q = r.grid!.basis.local(a.goal!.point),i = r.grid!.index(x:q.x,z:q.z)!
        r.grid!.cells[i].state = .obstacle;r.grid!.cells[i].obstacleSamples = 6
        let b = tracker.update(result:r,observation:nil,options:.init())
        XCTAssertNil(b.path);XCTAssertEqual(b.goal?.id,a.goal?.id)
        var latest = b
        for j in 3...6 { r.frameID = UInt64(j);r.timestamp = 1+Double(j-1)*0.1;latest = tracker.update(result:r,observation:nil,options:.init()) }
        XCTAssertNotEqual(latest.goal?.id,a.goal?.id)
        XCTAssertNotEqual(latest.path?.points.last,a.goal?.point)
    }
    func testGroundEvidenceExpiryHidesPathButPreservesFixedGoal() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init())
        var lost = missing(id:2,time:3.1)
        lost.diagnostics = AnalysisDiagnostics();lost.diagnostics?.groundReferenceInvalidation = "reference_expired_or_clock_reversed"
        let b = tracker.update(result:lost,observation:nil,options:.init())
        XCTAssertNil(b.path);XCTAssertEqual(b.goal?.id,a.goal?.id)
        let c = tracker.update(result:result(id:3,time:3.2),observation:nil,options:.init())
        XCTAssertEqual(c.goal?.id,a.goal?.id);XCTAssertEqual(c.path?.points.last,a.goal?.point)
    }
    func testClockReversalStillClearsFixedGoal() {
        var tracker = PathPredictor();_ = tracker.update(result:result(),observation:nil,options:.init())
        let b = tracker.update(result:result(id:2,time:0.5),observation:nil,options:.init())
        XCTAssertNil(b.path);XCTAssertNil(b.goal)
    }
    func testTransientBlockedGoalNeverDrawsOldPathOrSelectsNewGoal() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init())
        var r = result(id:2,time:1.1);let q = r.grid!.basis.local(a.goal!.point),i = r.grid!.index(x:q.x,z:q.z)!
        r.grid!.cells[i].state = .obstacle;r.grid!.cells[i].obstacleSamples = 6
        let b = tracker.update(result:r,observation:nil,options:.init())
        XCTAssertNil(b.path);XCTAssertEqual(b.goal?.id,a.goal?.id)
        let c = tracker.update(result:result(id:3,time:1.2),observation:nil,options:.init())
        XCTAssertEqual(c.goal?.id,a.goal?.id)
    }
    func testReRouteEndpointIsExactWorldGoalNotRoundedGridCentre() {
        let r = result(),blue = BluePathGrid(result:r)!,candidate = blue.search().points.last!+V3(0.01,0,0.01)
        let replanned = blue.search(fixedTarget:candidate)
        XCTAssertFalse(replanned.points.isEmpty);XCTAssertEqual(replanned.points.last,candidate)
        XCTAssertTrue(blue.supports(replanned.points))
    }
    func testPredictionBranchDoesNotNeedOrAlterVerifiedGuidanceFlag() {
        var r = result();r.sourceDirectionStable = false;r.diagnostics?.groundReferenceMode = "native_confirmed"
        var tracker = PathPredictor()
        XCTAssertNotNil(tracker.update(result:r,observation:nil,options:.init(),directionStable:true).path)
        XCTAssertEqual(r.sourceDirectionStable,false) // strict verified guidance remains disabled
        tracker.reset();XCTAssertNil(tracker.update(result:r,observation:nil,options:.init(),directionStable:false).path)
    }
    func testGoalWidthChangePreservesIntentButDoesNotRenderUnvalidatedWidth() {
        var tracker = PathPredictor();let a = tracker.update(result:result(),observation:nil,options:.init())
        var options = PathOptions();options.minimumWidth = 1.2
        let b = tracker.update(result:missing(id:2,time:1.1),observation:nil,options:options)
        XCTAssertEqual(b.goal?.id,a.goal?.id);XCTAssertNil(b.path)
    }
    func testLeftDoubleAndRightLongAreDistinctAndRepeatWithoutOverlap() {
        var left = PathHapticPolicy(),right = PathHapticPolicy()
        let ll = drive(&left,angle:-30,from:1,to:3),rr = drive(&right,angle:30,from:1,to:3)
        XCTAssertGreaterThan(ll.count,2);XCTAssertGreaterThan(rr.count,2)
        XCTAssertTrue(ll.allSatisfy{$0.kind == "left_double" && $0.segments?.count == 2})
        XCTAssertTrue(rr.allSatisfy{$0.kind == "right_long" && $0.segments?.count == 1})
        let pair = ll[0].segments!;XCTAssertGreaterThan(pair[1].relativeTime,pair[0].duration)
        XCTAssertLessThan(ll[0].duration,0.45);XCTAssertLessThan(rr[0].duration,0.45)
        XCTAssertLessThan(ll[0].intensity,1);XCTAssertLessThan(rr[0].intensity,1)
    }
    func testSideChangeInterruptsOldPatternImmediately() {
        var p = PathHapticPolicy()
        XCTAssertEqual(p.update(heading:heading(-20),now:1,enabled:true,threshold:12)?.kind,"left_double")
        XCTAssertEqual(p.update(heading:heading(20),now:1.02,enabled:true,threshold:12)?.kind,"right_long")
        XCTAssertTrue(p.stopCurrentPattern)
    }
    func testEnteringAlignmentCancelsDirectionalPulseBeforeStrongConfirmation() {
        var p = PathHapticPolicy();_ = p.update(heading:heading(20),now:1,enabled:true,threshold:12)
        XCTAssertNil(p.update(heading:heading(3),now:1.05,enabled:true,threshold:12));XCTAssertTrue(p.stopCurrentPattern)
        let strong = drive(&p,angle:3,from:1.1,to:1.5)
        XCTAssertEqual(strong.count,1);XCTAssertEqual(strong.first?.kind,"aligned_once")
        XCTAssertFalse(p.stopCurrentPattern) // The strong pulse is not cut off on the following tick.
    }
    func testRearmRequiresSustainedDeviationAndIgnoresBriefSpike() {
        var p = PathHapticPolicy();_ = drive(&p,angle:0,from:1,to:1.5)
        XCTAssertTrue(drive(&p,angle:14,from:1.55,to:1.7).isEmpty)
        XCTAssertTrue(drive(&p,angle:0,from:1.75,to:2.2).isEmpty)
        XCTAssertFalse(drive(&p,angle:-14,from:2.25,to:2.65).isEmpty)
        XCTAssertEqual(drive(&p,angle:0,from:2.7,to:3.1).filter{$0.kind == "aligned_once"}.count,1)
    }
    func testDwellCannotBridgeMissingFramesOrBackwardTime() {
        var p = PathHapticPolicy();_ = p.update(heading:heading(0),now:1,enabled:true,threshold:12)
        XCTAssertNil(p.update(heading:heading(0),now:2,enabled:true,threshold:12))
        XCTAssertNil(p.update(heading:heading(0),now:1.5,enabled:true,threshold:12));XCTAssertTrue(p.stopCurrentPattern)
        _ = p.update(heading:nil,now:2.1,enabled:true,threshold:12)
        XCTAssertNil(p.update(heading:heading(0),now:2.2,enabled:true,threshold:12))
    }
    func testLatchedAlignmentSurvivesPauseButExplicitNewGoalResetRearms() {
        var p = PathHapticPolicy();_ = drive(&p,angle:0,from:1,to:1.5)
        XCTAssertNil(p.update(heading:heading(20),now:1.6,enabled:false,threshold:12))
        XCTAssertTrue(drive(&p,angle:0,from:2,to:3).isEmpty)
        p.reset();XCTAssertEqual(drive(&p,angle:0,from:4,to:4.4).filter{$0.kind == "aligned_once"}.count,1)
    }
    func testRejectedAlignmentSubmissionCanRetryButAcceptedOneStaysSilent() {
        var p = PathHapticPolicy()
        let failed = drive(&p,angle:0,from:1,to:1.4).first!
        p.reject(failed)
        _ = p.update(heading:nil,now:1.5,enabled:false,threshold:12)
        let retry = drive(&p,angle:0,from:3,to:3.4)
        XCTAssertEqual(retry.count,1);XCTAssertEqual(retry.first?.kind,"aligned_once")
        XCTAssertTrue(drive(&p,angle:0,from:3.45,to:4).isEmpty)
    }
    func testTrackedTurnCanKeepAngularFeedbackWithoutReselectingGoal() {
        let p = path();var g = gate();g.directionStable = false
        let pose = yawPose(10)
        let shown = PathPresentation.make(path:p,gate:g,pose:pose,options:.init(),now:1.1)
        XCTAssertNotNil(shown);XCTAssertNotNil(PathTracking.heading(path:shown!.path,pose:pose,lookAhead:0.8))
    }
    func testNewOptionsMigrateAndBoundAlignmentBelowRearmAngle() throws {
        let o = try JSONDecoder().decode(PathOptions.self,from:Data(#"{"minimumWidth":0.5,"haptics":false}"#.utf8))
        XCTAssertEqual(o.targetHalfAngleDegrees,45);XCTAssertEqual(o.arrivalRadius,0.35);XCTAssertFalse(o.haptics)
        var bad = o;bad.deviationDegrees = 6;bad.alignmentDegrees = 12;bad.targetHalfAngleDegrees = .nan;bad.arrivalRadius = -1
        XCTAssertEqual(bad.validated().alignmentDegrees,4);XCTAssertEqual(bad.validated().targetHalfAngleDegrees,45);XCTAssertEqual(bad.validated().arrivalRadius,0.2)
    }
}
