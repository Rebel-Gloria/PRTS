import XCTest
import simd
@testable import SpatialCore

final class GroundContinuityTests: XCTestCase {
    private let plane = GroundPlane(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
    private let pose = RigidPose(position:V3(0,1.4,0))
    private func primed() -> GroundReferenceTracker {
        var tracker = GroundReferenceTracker()
        for i in 0..<3 {
            let r = tracker.update(fitted:plane,pose:pose,time:10+Double(i)*0.1,frameID:UInt64(i+1),epoch:1,parameterVersion:0)
            XCTAssertEqual(r.currentConfirmed,i == 2)
        }
        return tracker
    }
    func testGroundConfirmationIsInvariantToWorldOriginTranslation() {
        for translation: Float in [0,20,80,-40] {
            var tracker = GroundReferenceTracker()
            let camera = RigidPose(position:V3(translation,1.4,0))
            for i in 0..<3 {
                let angle: Float = Float(i) * 0.7 * .pi/180
                let normal = V3(sin(angle),cos(angle),0)
                let localPlane = GroundPlane(normal:normal,offset:-simd_dot(normal,V3(translation,0,0)),floorPriorConfirmed:true)
                let r = tracker.update(fitted:localPlane,pose:camera,time:10+Double(i)*0.1,frameID:UInt64(i+1),epoch:1,parameterVersion:0)
                XCTAssertEqual(r.currentConfirmed,i == 2,"world translation \(translation)")
            }
        }
    }
    func testRealLocalHeightJumpStillBreaksConsecutiveConfirmation() {
        var tracker = primed()
        let movedFloor = GroundPlane(normal:V3(0,1,0),offset:-0.06,floorPriorConfirmed:true)
        let r = tracker.update(fitted:movedFloor,pose:pose,time:10.3,frameID:4,epoch:1,parameterVersion:0)
        XCTAssertFalse(r.currentConfirmed); XCTAssertEqual(r.confirmations,1)
    }
    func testSurfaceBudgetHonorsStepTwoAtSensorResolutionWithoutUnboundedTriangles() {
        XCTAssertEqual(SurfaceModelBuilder.samplingStep(width:256,height:192,requested:2),2)
        XCTAssertEqual(SurfaceModelBuilder.samplingStep(width:256,height:192,requested:4),4)
        for (w,h) in [(256,192),(512,384),(1920,1440)] {
            let step = SurfaceModelBuilder.samplingStep(width:w,height:h,requested:1)
            XCTAssertLessThanOrEqual(2*((w-1)/step)*((h-1)/step),SurfaceModelBuilder.triangleBudget)
        }
    }
    func testMissingGroundRetainsWorldReferenceButDoesNotRenewItsAge() throws {
        var tracker = primed()
        for i in 0..<10 {
            var moving = pose; moving.position.x += Float(i)*0.02
            let r = tracker.update(fitted:nil,pose:moving,time:10.3+Double(i)*0.1,frameID:UInt64(i+4),epoch:1,parameterVersion:0)
            XCTAssertEqual(try XCTUnwrap(r.reference).observedAt,10.2)
            XCTAssertEqual(r.reference?.frameID,3); XCTAssertFalse(r.currentConfirmed); XCTAssertEqual(r.confirmations,0)
        }
        XCTAssertNil(tracker.update(fitted:nil,pose:pose,time:12.21,frameID:30,epoch:1,parameterVersion:0).reference)
    }
    func testReacquisitionNeedsThreeCurrentMeasurementsWhileGeometryCanContinue() {
        var tracker = primed()
        _ = tracker.update(fitted:nil,pose:pose,time:10.3,frameID:4,epoch:1,parameterVersion:0)
        for i in 0..<3 {
            let r = tracker.update(fitted:plane,pose:pose,time:10.4+Double(i)*0.1,frameID:UInt64(i+5),epoch:1,parameterVersion:0)
            XCTAssertNotNil(r.reference); XCTAssertEqual(r.currentConfirmed,i == 2)
        }
    }
    func testReferenceInvalidatesOnMotionHeightConflictEpochParametersAndClock() {
        for variant in 0..<7 {
            var tracker = primed(),moved = pose
            if variant == 0 { moved.position.x += 1.01 }
            if variant == 1 { moved.position.y += 0.36 }
            let floor = GroundPlane(normal:V3(0,1,0),offset:-0.3,floorPriorConfirmed:true)
            let r = tracker.update(fitted:variant == 2 ? floor : nil,pose:moved,time:variant == 3 ? 10.1 : variant == 6 ? .nan : 10.3,
                                   frameID:4,epoch:variant == 4 ? 2 : 1,parameterVersion:variant == 5 ? 1 : 0)
            XCTAssertNil(r.reference,"variant \(variant)"); XCTAssertFalse(r.currentConfirmed)
        }
    }
    func testUnconfirmedTableCannotCreateOrRefreshReference() {
        var tracker = GroundReferenceTracker()
        let table = GroundPlane(normal:V3(0,1,0),offset:-0.7,floorPriorConfirmed:false)
        for i in 0..<5 {
            XCTAssertNil(tracker.update(fitted:table,pose:pose,time:10+Double(i)*0.1,frameID:UInt64(i+1),epoch:1,parameterVersion:0).reference)
        }
        tracker = primed()
        XCTAssertEqual(tracker.update(fitted:table,pose:pose,time:10.4,frameID:5,epoch:1,parameterVersion:0).reference?.observedAt,10.2)
    }
    func testSteepPitchKeepsGeometryBasisWithoutAuthorizingHeading() throws {
        for degrees: Float in [65,85,90] {
            let a = degrees * .pi/180
            let tilted = RigidPose(right:V3(1,0,0),up:V3(0,cos(a),-sin(a)),back:V3(0,sin(a),cos(a)),position:pose.position)
            XCTAssertNil(GroundBasis(plane:plane,pose:tilted))
            let basis = try XCTUnwrap(GroundBasis.geometry(plane:plane,pose:tilted,previousForward:V3(0,0,-1)))
            XCTAssertEqual(simd_dot(basis.forward,plane.normal),0,accuracy:0.00001)
            let p = V3(0.3,0.2,-1),q = basis.local(p)
            XCTAssertLessThan(simd_distance(p,basis.world(x:q.x,h:q.y,z:q.z)),0.00001)
        }
    }
    private func modelResult(id: UInt64 = 10,time: Double = 10) -> AnalysisResult {
        var r = AnalysisResult(epoch:1,frameID:id,timestamp:time,parameters:.init(),status:"synthetic",source:"synthetic")
        r.sourcePose = pose; r.sourceDirectionStable = true
        r.surfaceModel = .init(triangles:[.init(a:V3(0,0,-1),b:V3(0.1,0,-1),c:V3(0,0,-1.1),surface:.ground)],
            summary:.init(groundTriangles:1,protrusionTriangles:0,minimumProtrusionHeight:0.05,samplingStep:2))
        return r
    }
    private func gate(time: Double = 10.5) -> ResultPresentationGate {
        var g = ResultPresentationGate(); g.enabled = true; g.trackingNormal = true; g.directionStable = true
        g.epoch = 1; g.frameID = 20; g.frameTimestamp = time; return g
    }
    func testHistoryIsExplicitAndCannotExtendGuidanceOrCurrentResultLifetime() throws {
        let r = modelResult(); var history = SurfaceHistory(); history.ingest(r)
        let g = gate()
        let shown = try XCTUnwrap(history.presentation(current:nil,gate:g,pose:pose,now:10.5))
        XCTAssertTrue(shown.historical); XCTAssertEqual(shown.age,0.5)
        XCTAssertFalse(g.allowsGeometry(shown.result,now:10.5)); XCTAssertFalse(g.allowsGuidance(shown.result,now:10.5))
        XCTAssertNil(history.presentation(current:nil,gate:gate(time:11.01),pose:pose,now:11.01))
    }
    func testHistoryNeverFreezesToScreenCoordinatesAndIsBoundedByTranslation() throws {
        var history = SurfaceHistory(); history.ingest(modelResult())
        var moved = pose; moved.position.x = 0.2
        let shown = try XCTUnwrap(history.presentation(current:nil,gate:gate(),pose:moved,now:10.5))
        let vertex = try XCTUnwrap(shown.result.surfaceModel?.triangles.first).a
        XCTAssertEqual(vertex,V3(0,0,-1)); XCTAssertEqual(moved.camera(vertex).x,-0.2,accuracy:0.0001)
        moved.position.x = 0.76
        XCTAssertNil(history.presentation(current:nil,gate:gate(),pose:moved,now:10.5))
    }
    func testHistoryCannotSurviveTrackingBarrierStopStalePoseEpochOrParameters() {
        var history = SurfaceHistory(); history.ingest(modelResult())
        for i in 0..<7 {
            var g = gate()
            switch i {
            case 0: g.enabled = false
            case 1: g.trackingNormal = false
            case 2: g.minimumGeometryFrameID = 11
            case 3: g.epoch = 2
            case 4: g.parameterVersion = 1
            case 5: g.frameTimestamp = 10.1
            default: g.frameTimestamp = 10.6
            }
            XCTAssertNil(history.presentation(current:nil,gate:g,pose:pose,now:10.5),"variant \(i)")
        }
        history.reset(); XCTAssertNil(history.presentation(current:nil,gate:gate(),pose:pose,now:10.5))
    }
    func testCurrentEmptyModelClearsHistoryAndLateResultsCannotReviveIt() {
        var history = SurfaceHistory(); history.ingest(modelResult())
        var empty = modelResult(id:11,time:10.1); empty.surfaceModel?.triangles = []
        history.ingest(empty); history.ingest(modelResult())
        XCTAssertNil(history.presentation(current:nil,gate:gate(),pose:pose,now:10.5))
    }
    func testGroundContradictionClearsHistoryAndRetainedReferenceNeverAuthorizesGuidance() {
        var history = SurfaceHistory(); history.ingest(modelResult())
        var conflict = modelResult(id:11,time:10.1); conflict.surfaceModel = nil; conflict.diagnostics = .init()
        conflict.diagnostics?.groundReferenceInvalidation = "reference_conflicts_with_current_floor"
        history.ingest(conflict)
        XCTAssertNil(history.presentation(current:nil,gate:gate(),pose:pose,now:10.5))
        var r = modelResult(); r.diagnostics = .init(); r.diagnostics?.groundReferenceMode = "retained_world_reference"
        XCTAssertFalse(gate(time:10.1).allowsGuidance(r,now:10.1))
        XCTAssertTrue(gate(time:10.1).allowsGeometry(r,now:10.1))
    }
}
