import XCTest
import simd
@testable import SpatialCore

final class PathPredictionTests: XCTestCase {
    // Explicitly synthetic blue geometry. No sensor accuracy or physical clearance ground truth.
    func result(id: UInt64 = 1,time: Double = 1,hole: ((Int,Int)->Bool)? = nil) -> AnalysisResult {
        let p = ProbeParameters(),pose = RigidPose(position:V3(0,1.4,0))
        let plane = GroundPlane(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
        var r = AnalysisResult(epoch:1,frameID:id,timestamp:time,parameters:p,status:"synthetic test",source:"synthetic")
        var grid = LocalGrid(basis:GroundBasis(plane:plane,pose:pose)!,parameters:p,timestamp:time,frameID:id,epoch:1)
        var triangles: [SurfaceTriangle] = []
        for z in 2..<grid.rows { for x in 0..<grid.columns where hole?(x,z) != true {
            grid.cells[z*grid.columns+x].groundSamples = 8
            grid.cells[z*grid.columns+x].observedAt = time
            let c = grid.center(z*grid.columns+x),s = grid.cellSize/2
            let a = grid.basis.world(x:c.x-s,h:0,z:c.y-s),b = grid.basis.world(x:c.x+s,h:0,z:c.y-s)
            let d = grid.basis.world(x:c.x-s,h:0,z:c.y+s),e = grid.basis.world(x:c.x+s,h:0,z:c.y+s)
            triangles += [.init(a:a,b:b,c:d,surface:.ground),.init(a:b,b:e,c:d,surface:.ground)]
        }}
        r.grid = grid; r.plane = plane; r.sourcePose = pose; r.sourceDirectionStable = true
        r.diagnostics = AnalysisDiagnostics(); r.diagnostics?.groundReferenceMode = "current_confirmed"
        r.surfaceModel = .init(triangles:triangles,summary:.init(groundTriangles:triangles.count,protrusionTriangles:0,minimumProtrusionHeight:0.05,maximumObservedProtrusionHeight:nil,samplingStep:2))
        return r
    }
    func missing(id: UInt64,time: Double) -> AnalysisResult { var r = result(id:id,time:time); r.surfaceModel = nil; r.grid = nil; r.plane = nil; return r }
    func path() -> PredictedPath { var p = PathPredictor(obstacleConfirmationSeconds: 0); return p.update(result:result(),observation:nil,options:.init()).path! }
    func gate() -> ResultPresentationGate {
        var g = ResultPresentationGate(); g.enabled = true; g.trackingNormal = true; g.directionStable = true
        g.epoch = 1; g.frameID = 10; g.frameTimestamp = 1.1; return g
    }
    func heading(_ angle: Float = 0,cross: Float = 0) -> PathHeading {
        .init(angleDegrees:angle,crossTrack:cross,startDistance:0.7,target:V3(0,0,-1),remainingLength:2)
    }
    func testSingleForwardLineStaysInsideBlueFootprint() {
        let r = result(),raster = BluePathGrid(result:r)!,p = path()
        XCTAssertGreaterThan(p.length,2); XCTAssertTrue(raster.supports(p.points))
        XCTAssertLessThan(abs(p.points.last!.x),0.001) // Clear area stays on the forward axis.
        XCTAssertLessThan(p.points[0].z,-0.3) // Observed path still excludes the separately drawn unknown approach.
        XCTAssertTrue(r.grid!.cells.allSatisfy { $0.state == .unknown }) // No clearance inflation.
    }
    func testUnknownFullWidthGapTruncatesInsteadOfJumping() {
        let r = result(hole:{ _,z in z == 20 }),raster = BluePathGrid(result:r)!
        let points = raster.plan()
        XCTAssertGreaterThanOrEqual(points.count,2); XCTAssertTrue(points.allSatisfy { -$0.z < 1.8 }); XCTAssertTrue(raster.supports(points))
    }
    func testSubcellHoleIsNotFilledByThePlane() {
        let r = result(hole:{ x,z in x == 15 && z == 15 }),b = BluePathGrid(result:r)!
        XCTAssertFalse(b.mask[15*b.grid.columns+15]); XCTAssertEqual(b.grid.cells[15*b.grid.columns+15].state,.unknown)
    }
    func testNarrowBlueStripCannotFitBody() {
        var wide = PathOptions();wide.minimumWidth = 0.9
        let r = result(hole:{ x,_ in x < 12 || x > 17 })
        XCTAssertTrue(BluePathGrid(result:r,options:wide)!.plan().isEmpty)
        XCTAssertFalse(BluePathGrid(result:r)!.plan().isEmpty) // Requested 0.50m envelope fits.
    }
    func testObstacleAndItsInflatedFootprintAreAvoided() {
        var r = result(); let i = r.grid!.index(x:0,z:1.8)!
        r.grid!.cells[i].state = .obstacle; r.grid!.cells[i].obstacleSamples = 4
        let b = BluePathGrid(result:r)!,points = b.plan()
        XCTAssertFalse(points.isEmpty); XCTAssertTrue(b.supports(points))
        for p in points { XCTAssertGreaterThan(simd_distance(p,V3(0.05,0,-1.85)),0.25) }
    }
    func testSingleSuspectPixelCannotBePlannedThrough() {
        var r = result();let i = r.grid!.index(x:0,z:2)!
        r.grid!.cells[i].obstacleSamples = 1
        XCTAssertFalse(BluePathGrid(result:r)!.mask[i])
    }
    func testNonBlueProtrusionTrianglesCannotAuthorizePath() {
        var r = result(); r.surfaceModel!.triangles = r.surfaceModel!.triangles.map { var t = $0;t.surface = .protrusion;return t }
        XCTAssertTrue(BluePathGrid(result:r)!.plan().isEmpty)
    }
    func testWorldPathDoesNotRotateWithPhoneWhenBlueUnavailable() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);let old = tracker.update(result:result(),observation:nil,options:.init()).path!
        var r = missing(id:2,time:1.2);r.sourcePose = .init(right:V3(0,0,-1),up:V3(0,1,0),back:V3(1,0,0),position:V3(0,1.4,0))
        let retained = tracker.update(result:r,observation:nil,options:.init())
        XCTAssertEqual(retained.reason,"retained_world_path");XCTAssertEqual(retained.path?.points,old.points)
    }
    func testShortDropoutRetainsButExpiresWithoutEvidence() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);_ = tracker.update(result:result(),observation:nil,options:.init())
        XCTAssertNotNil(tracker.update(result:missing(id:2,time:2.9),observation:nil,options:.init()).path)
        XCTAssertNil(tracker.update(result:missing(id:3,time:3.01),observation:nil,options:.init()).path)
    }
    func testRevalidationDoesNotCreateNewPathIdentity() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);let p = tracker.update(result:result(),observation:nil,options:.init()).path!
        let next = tracker.update(result:result(id:2,time:1.2),observation:nil,options:.init()).path!
        XCTAssertEqual(next.id,p.id);XCTAssertEqual(next.points,p.points);XCTAssertEqual(next.observedAt,1.2)
    }
    func testCurrentObstacleReplacesOldPathWithObservedPrefixImmediately() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);let p = tracker.update(result:result(),observation:nil,options:.init()).path!
        var r = result(id:2,time:1.1);let c = r.grid!.basis.local(p.points[p.points.count/2]),i = r.grid!.index(x:c.x,z:c.z)!
        r.grid!.cells[i].state = .obstacle;r.grid!.cells[i].obstacleSamples = 5;r.surfaceModel = nil
        let update = tracker.update(result:r,observation:nil,options:.init())
        XCTAssertNotNil(update.path);XCTAssertEqual(update.reason,"obstacle_ahead_truncated")
        XCTAssertTrue(RoutePlanningGrid(result:r)!.supports(update.path!.points))
        XCTAssertNotEqual(update.path?.points.last,p.points.last)
    }
    func testRawCurrentDepthVetoesHistoryWithoutAnyNewGroundFit() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);let route = tracker.update(result:result(),observation:nil,options:.init()).path!
        let a = route.points.first!,b = route.points.last!,x = a.x+(b.x-a.x)*(-1.5-a.z)/(b.z-a.z)
        let r = missing(id:2,time:1.1),k = CameraIntrinsics(fx:200,fy:200,cx:1.5-x*200/1.5,cy:1.5,width:4,height:4)
        let o = DepthObservation(width:4,height:4,depth:Array(repeating:1.5,count:16),confidence:Array(repeating:2,count:16),intrinsics:k,pose:r.sourcePose!,timestamp:1.1,frameID:2,epoch:1)
        let update = tracker.update(result:r,observation:o,options:.init())
        XCTAssertNil(update.path);XCTAssertEqual(update.reason,"current_obstacle_invalidated")
    }
    func testLowConfidenceRawDepthCannotFabricateConfirmedObstacle() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);let route = tracker.update(result:result(),observation:nil,options:.init()).path!
        let a = route.points.first!,b = route.points.last!,x = a.x+(b.x-a.x)*(-1.5-a.z)/(b.z-a.z)
        let r = missing(id:2,time:1.1),k = CameraIntrinsics(fx:200,fy:200,cx:1.5-x*200/1.5,cy:1.5,width:4,height:4)
        let o = DepthObservation(width:4,height:4,depth:Array(repeating:1.5,count:16),confidence:Array(repeating:0,count:16),intrinsics:k,pose:r.sourcePose!,timestamp:1.1,frameID:2,epoch:1)
        let update = tracker.update(result:r,observation:o,options:.init())
        XCTAssertNotNil(update.path);XCTAssertEqual(update.path?.observedAt,1) // Does NOT refresh evidence.
    }
    func testClosedNarrowObstacleCorridorCannotFitBody() {
        var r = result()
        for z in 0..<r.grid!.rows { for x in [11,18] { let i = z*r.grid!.columns+x;r.grid!.cells[i].state = .obstacle;r.grid!.cells[i].obstacleSamples = 4 } }
        var wide = PathOptions();wide.minimumWidth = 0.9
        let b = BluePathGrid(result:r,options:wide)!
        XCTAssertFalse(b.mask.enumerated().contains { $0.element && (12...17).contains($0.offset%b.grid.columns) })
    }
    func testHapticHoldDoesNotRearmBecauseOneAnalysisFrameIsMissing() {
        var policy = PathHapticPolicy()
        let pulses = drive(&policy,angle:0,from:1,to:1.4)
        XCTAssertEqual(pulses.filter{$0.kind == "aligned_once"}.count,1)
        _ = policy.update(heading:nil,now:1.5,enabled:true,threshold:12)
        XCTAssertTrue(drive(&policy,angle:0,from:1.6,to:2.2).isEmpty)
    }
    func testGroundConflictClearsWithoutReplanningSameFrame() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);_ = tracker.update(result:result(),observation:nil,options:.init())
        var r = result(id:2,time:1.1);r.diagnostics?.groundReferenceInvalidation = "ground_conflict"
        XCTAssertNil(tracker.update(result:r,observation:nil,options:.init()).path)
    }
    func testEpochParameterAndResetIsolation() {
        for mode in 0..<3 {
            var tracker = PathPredictor(obstacleConfirmationSeconds: 0);_ = tracker.update(result:result(),observation:nil,options:.init())
            var r = missing(id:2,time:1.1)
            if mode == 0 { r.epoch = 2 } else if mode == 1 { r.parameterVersion = 1 } else { tracker.reset() }
            XCTAssertNil(tracker.update(result:r,observation:nil,options:.init()).path)
        }
    }
    func testOutOfOrderCannotOverwriteNewerPath() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);let p = tracker.update(result:result(id:4,time:1),observation:nil,options:.init()).path!
        XCTAssertEqual(tracker.update(result:missing(id:2,time:1.2),observation:nil,options:.init()).path?.validatedFrameID,p.validatedFrameID)
    }
    func testMonocularConfirmedBlueGetsExperimentalLineButNoVerifiedGrid() {
        var r = result();r.source = "apple_coreml_relative_depth_arkit_alignment";r.diagnostics?.groundReferenceMode = "native_confirmed"
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);XCTAssertNotNil(tracker.update(result:r,observation:nil,options:.init()).path)
        XCTAssertTrue(r.grid!.cells.allSatisfy{$0.state == .unknown});XCTAssertTrue(r.segments.isEmpty)
    }
    func testProvisionalPlaneDoesNotStartNewPath() {
        var r = result();r.diagnostics?.groundReferenceMode = "native_provisional_ground"
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);XCTAssertNil(tracker.update(result:r,observation:nil,options:.init()).path)
    }
    func testPresentationRejectsBackgroundStaleFramesBarriersAndEpoch() {
        let p = path(),pose = result().sourcePose!
        XCTAssertNotNil(PathPresentation.make(path:p,gate:gate(),pose:pose,options:.init(),now:1.1))
        for mode in 0..<5 {
            var g = gate()
            switch mode {case 0:g.enabled = false;case 1:g.trackingNormal = false;case 2:g.minimumGeometryFrameID = 2;case 3:g.epoch = 2;default:g.frameTimestamp = 0}
            XCTAssertNil(PathPresentation.make(path:p,gate:g,pose:pose,options:.init(),now:1.1))
        }
    }
    func testPresentationUsesTTLWhileLiveFramesContinue() {
        let p = path(),pose = result().sourcePose!;var g = gate();g.frameTimestamp = 2
        XCTAssertTrue(PathPresentation.make(path:p,gate:g,pose:pose,options:.init(),now:2)!.historical)
        g.frameTimestamp = 3.1;XCTAssertNil(PathPresentation.make(path:p,gate:g,pose:pose,options:.init(),now:3.1))
    }
    func testPurePursuitSignsAndLateralOffset() {
        var p = path();p.points = [V3(0,0,-0.5),V3(0,0,-3.5)]
        let pose = result().sourcePose!
        XCTAssertLessThan(abs(PathTracking.heading(path:p,pose:pose,lookAhead:0.8)!.angleDegrees),4)
        var left = pose;left.position.x = -0.5
        let h = PathTracking.heading(path:p,pose:left,lookAhead:0.8)!
        XCTAssertGreaterThan(h.angleDegrees,10);XCTAssertGreaterThan(h.crossTrack,0.4)
        var right = pose;right.position.x = 0.5
        XCTAssertLessThan(PathTracking.heading(path:p,pose:right,lookAhead:0.8)!.angleDegrees,-10)
    }
    func testNearVerticalPitchAndUnstableHeadingDoNotRemoveWorldLine() {
        let down = RigidPose(right:V3(1,0,0),up:V3(0,0,-1),back:V3(0,1,0),position:V3(0,1.4,0))
        var g = gate();g.directionStable = false
        XCTAssertNotNil(PathPresentation.make(path:path(),gate:g,pose:down,options:.init(),now:1.1))
        XCTAssertNil(PathTracking.heading(path:path(),pose:down,lookAhead:0.8))
    }
    func testPhonePitchDoesNotMakeHeadingOrSuccessWithoutGroundProjection() {
        let down = RigidPose(right:V3(1,0,0),up:V3(0,0,-1),back:V3(0,1,0),position:V3(0,1.4,0))
        XCTAssertNil(PathTracking.heading(path:path(),pose:down,lookAhead:0.8))
    }
    func testRemainingPathDoesNotBridgeNearBlindZoneAndStopsAtEnd() {
        var p = path();p.points = [V3(0,0,-0.5),V3(0,0,-3.5)]
        var pose = result().sourcePose!;pose.position.z = (p.points.first!.z+p.points.last!.z)/2
        let points = PathTracking.remaining(p.points,plane:p.plane,pose:pose)
        XCTAssertLessThanOrEqual(points.count,p.points.count);XCTAssertLessThan(points[0].z,p.points[0].z);XCTAssertGreaterThan(simd_distance(points[0],points[1]),0.001)
        pose.position.z = p.points.last!.z-0.2
        XCTAssertNil(PathTracking.heading(path:p,pose:pose,lookAhead:0.8))
    }
    func drive(_ p: inout PathHapticPolicy,angle: Float,from: Double,to: Double,cross: Float = 0) -> [PathHapticPulse] {
        stride(from:from,through:to+0.00001,by:0.05).compactMap { p.update(heading:heading(angle,cross:cross),now:$0,enabled:true,threshold:12) }
    }
    func testHapticsDeviationIncreasesIntensityAndCadence() {
        var low = PathHapticPolicy(),high = PathHapticPolicy()
        let l = drive(&low,angle:13,from:1,to:3),h = drive(&high,angle:60,from:1,to:3)
        XCTAssertGreaterThan(h[0].intensity,l[0].intensity);XCTAssertGreaterThan(h[0].duration,l[0].duration)
        XCTAssertGreaterThan(h.count,l.count)
    }
    func testAlignmentSingleStrongPulseDwellAndRearm() {
        var p = PathHapticPolicy()
        let first = drive(&p,angle:0,from:1,to:4)
        XCTAssertEqual(first.count,1);XCTAssertEqual(first.first?.kind,"aligned_once");XCTAssertEqual(first.first?.intensity,1)
        XCTAssertTrue(drive(&p,angle:10,from:4.1,to:5).isEmpty) // Below the 12° rearm threshold.
        XCTAssertTrue(drive(&p,angle:0,from:5.1,to:6).isEmpty)
        XCTAssertFalse(drive(&p,angle:15,from:6.1,to:6.6).isEmpty)
        XCTAssertEqual(drive(&p,angle:0,from:6.7,to:7.2).filter{$0.kind == "aligned_once"}.count,1)
    }
    func testAngularConfirmationDoesNotClaimPositionAlignment() {
        var p = PathHapticPolicy()
        XCTAssertEqual(drive(&p,angle:0,from:1,to:2,cross:0.4).filter{$0.kind == "aligned_once"}.count,1)
        var jitter = PathHapticPolicy()
        _ = drive(&jitter,angle:0,from:4,to:4.15)
        _ = jitter.update(heading:heading(6),now:4.2,enabled:true,threshold:12)
        XCTAssertNil(jitter.update(heading:heading(),now:4.3,enabled:true,threshold:12))
    }
    func testNoFeedbackWhenDisabledMissingOrNonFinite() {
        var p = PathHapticPolicy()
        XCTAssertNil(p.update(heading:heading(50),now:1,enabled:false,threshold:12))
        XCTAssertNil(p.update(heading:nil,now:2,enabled:true,threshold:12))
        XCTAssertNil(p.update(heading:heading(.nan),now:3,enabled:true,threshold:12))
    }
    func testOptionsAreBoundedAndRoundTrip() throws {
        var o = PathOptions();o.retentionSeconds = 99;o.deviationDegrees = .nan;o.lookAhead = 0
        let v = o.validated();XCTAssertEqual(v.retentionSeconds,5);XCTAssertEqual(v.deviationDegrees,12);XCTAssertEqual(v.lookAhead,0.4)
        XCTAssertEqual(try JSONDecoder().decode(PathOptions.self,from:JSONEncoder().encode(v)),v)
    }
    func testDisabledClearsRetainedRoute() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0);_ = tracker.update(result:result(),observation:nil,options:.init());var o = PathOptions();o.enabled = false
        XCTAssertNil(tracker.update(result:result(id:2,time:1.1),observation:nil,options:o).path)
    }
}
