import XCTest
import simd
@testable import SpatialCore

final class MotionPresentationTests: XCTestCase {
    private func result(stable: Bool = true) -> AnalysisResult {
        var r = AnalysisResult(epoch:2,frameID:100,timestamp:10,parameters:.init(),parameterVersion:3,status:"synthetic",source:"synthetic")
        r.sourceDirectionStable = stable
        return r
    }
    private func gate() -> ResultPresentationGate {
        var g = ResultPresentationGate()
        g.enabled = true; g.trackingNormal = true; g.directionStable = true
        g.epoch = 2; g.parameterVersion = 3; g.frameID = 106; g.frameTimestamp = 10.1
        return g
    }
    func testMovingButTrackedKeepsGeometryAndWithdrawsGuidance() {
        var g = gate(); g.directionStable = false
        XCTAssertTrue(g.allowsGeometry(result(stable:false),now:10.15))
        XCTAssertFalse(g.allowsGuidance(result(stable:false),now:10.15))
        // An earlier stationary source frame also cannot keep its yellow line/directional distance.
        XCTAssertTrue(g.allowsGeometry(result(),now:10.15))
        XCTAssertFalse(g.allowsGuidance(result(),now:10.15))
    }
    func testStableCurrentFrameCannotAuthorizeAnUnstableSource() {
        let g = gate()
        XCTAssertTrue(g.allowsGeometry(result(stable:false),now:10.15))
        XCTAssertFalse(g.allowsGuidance(result(stable:false),now:10.15))
        XCTAssertTrue(g.allowsGuidance(result(),now:10.15))
    }
    func testFreshnessCutoffStillAppliesWhileMoving() {
        var g = gate(); g.directionStable = false; g.frameTimestamp = 10.24
        XCTAssertTrue(g.allowsGeometry(result(stable:false),now:10.25))
        XCTAssertFalse(g.allowsGeometry(result(stable:false),now:10.251))
    }
    func testStaleOrFutureDisplayFrameAndFutureResultAreRejected() {
        var g = gate(),r = result()
        g.frameTimestamp = 9.5
        XCTAssertFalse(g.allowsGeometry(r,now:10.15))
        g.frameTimestamp = 10.2
        XCTAssertFalse(g.allowsGeometry(r,now:10.15))
        g = gate(); r.timestamp = 10.11 // Source is later than the displayed frame, even if before now.
        XCTAssertFalse(g.allowsGeometry(r,now:10.15))
        r.timestamp = 10.2
        XCTAssertFalse(g.allowsGeometry(r,now:10.15))
    }
    func testTrackingLossWithdrawsBothLayers() {
        var g = gate(); g.trackingNormal = false
        XCTAssertFalse(g.allowsGeometry(result(),now:10.15))
        XCTAssertFalse(g.allowsGuidance(result(),now:10.15))
    }
    func testStopFreezeAndCriticalThermalDisableOutput() {
        // SharedSnapshot combines these lifecycle conditions into enabled before using this gate.
        var g = gate(); g.enabled = false
        XCTAssertFalse(g.allowsGeometry(result(),now:10.15))
        XCTAssertFalse(g.allowsGuidance(result(),now:10.15))
    }
    func testEpochParametersAndFrameOrderRemainIsolated() {
        let g = gate(); var r = result()
        r.epoch = 1; XCTAssertFalse(g.allowsGeometry(r,now:10.15))
        r = result(); r.parameterVersion = 2; XCTAssertFalse(g.allowsGeometry(r,now:10.15))
        r = result(); r.frameID = 107; XCTAssertFalse(g.allowsGeometry(r,now:10.15))
    }
    func testPendingWorkCannotRestorePreTrackingLossGeometry() {
        var g = gate(); g.minimumGeometryFrameID = 101
        XCTAssertFalse(g.allowsGeometry(result(),now:10.15))
        var fresh = result(); fresh.frameID = 101
        XCTAssertTrue(g.allowsGeometry(fresh,now:10.15))
    }
    func testPreTurnGuidanceCannotReappearEvenAfterQuickRecovery() {
        var g = gate(); g.minimumGuidanceFrameID = 101
        XCTAssertTrue(g.allowsGeometry(result(),now:10.15))
        XCTAssertFalse(g.allowsGuidance(result(),now:10.15))
        var fresh = result(); fresh.frameID = 101
        XCTAssertTrue(g.allowsGuidance(fresh,now:10.15))
    }
    func testLegacyUnknownSourceStabilityNeverAuthorizesGuidance() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(result())) as? [String:Any])
        object.removeValue(forKey:"sourceDirectionStable")
        let old = try JSONDecoder().decode(AnalysisResult.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(old.sourceDirectionStable)
        XCTAssertTrue(gate().allowsGeometry(old,now:10.15))
        XCTAssertFalse(gate().allowsGuidance(old,now:10.15))
    }
    func testNonFiniteTimesNeverAuthorizeOutput() {
        var g = gate(),r = result()
        XCTAssertFalse(g.allowsGeometry(r,now:.nan))
        XCTAssertFalse(g.allowsGeometry(r,now:.infinity))
        r.timestamp = .nan; XCTAssertFalse(g.allowsGeometry(r,now:10.15))
        r = result(); g.frameTimestamp = .nan; XCTAssertFalse(g.allowsGeometry(r,now:10.15))
    }

    // SYNTHETIC fixed world: ground y=0, a 25 cm box, far wall. Rays are regenerated for each pose,
    // not copied from one stationary frame or presented as a device replay.
    private func scene(index: Int, box: Bool = true, confidence: UInt8 = 2, pitchDegrees: Float? = nil) -> (DepthObservation,[FloorPrior]) {
        let k = CameraIntrinsics(fx:100,fy:100,cx:63.5,cy:47.5,width:128,height:96)
        let yaw = Float(index)*4 * .pi/180, pitch = (pitchDegrees ?? Float(25+index%3)) * .pi/180
        func rotate(_ v: V3) -> V3 { V3(cos(yaw)*v.x+sin(yaw)*v.z,v.y,-sin(yaw)*v.x+cos(yaw)*v.z) }
        let pose = RigidPose(right:rotate(V3(1,0,0)),up:rotate(V3(0,cos(pitch),-sin(pitch))),
                             back:rotate(V3(0,sin(pitch),cos(pitch))),position:V3(Float(index)*0.01,1.3,-Float(index)*0.01))
        let lower = V3(-0.45,0,-2.3),upper = V3(0.45,0.25,-1.3)
        var depths: [Float] = []
        for v in 0..<k.height { for u in 0..<k.width {
            let ray = pose.world(k.unproject(u:Float(u),v:Float(v),depth:1))-pose.position
            var d: Float = ray.z < 0 ? (-5-pose.position.z)/ray.z : 10
            if ray.y < 0 { d = min(d,-pose.position.y/ray.y) }
            if box {
                var near: Float = 0,far = Float.infinity
                for axis in 0..<3 {
                    if abs(ray[axis]) < 1e-6 {
                        if pose.position[axis] < lower[axis] || pose.position[axis] > upper[axis] { far = -1 }
                    } else {
                        let a = (lower[axis]-pose.position[axis])/ray[axis],b = (upper[axis]-pose.position[axis])/ray[axis]
                        near = max(near,min(a,b)); far = min(far,max(a,b))
                    }
                }
                if near > 0,near <= far { d = min(d,near) }
            }
            depths.append(d)
        }}
        let time = 10+Double(index)*0.1
        let o = DepthObservation(width:k.width,height:k.height,depth:depths,confidence:Array(repeating:confidence,count:depths.count),
                                intrinsics:k,pose:pose,timestamp:time,frameID:UInt64(index+1),epoch:2)
        let priors = [V3(-0.7,0,-2),V3(0.7,0,-2),V3(-0.7,0,-3)].map { FloorPrior(center:$0,normal:V3(0,1,0),callbackTime:time) }
        return (o,priors)
    }
    func testContinuousYawPitchAndTranslationBuildFreshBlueRedAndColumns() throws {
        let analyzer = SpatialAnalyzer(); var direction = DirectionGate()
        let p = ProbeParameters()
        for i in 0..<8 {
            let (o,priors) = scene(index:i)
            let stable = direction.update(pose:o.pose,time:o.timestamp,trackingNormal:true,parameters:p)
            XCTAssertFalse(stable) // Rotation is deliberately faster than the guidance limit.
            let r = analyzer.analyze(o,priors:priors,parameters:p,parameterVersion:0,directionStable:stable,source:"synthetic")
            XCTAssertTrue(r.segments.isEmpty); XCTAssertTrue(r.distances.isEmpty)
            if i < 2 { XCTAssertNil(r.surfaceModel); continue }
            let m = try XCTUnwrap(r.surfaceModel)
            XCTAssertGreaterThan(m.summary.groundTriangles,0)
            XCTAssertGreaterThan(m.summary.protrusionTriangles,0)
            XCTAssertGreaterThan(try XCTUnwrap(m.blockingVolume).columns.count,0)
            XCTAssertEqual(r.frameID,o.frameID); XCTAssertEqual(r.timestamp,o.timestamp)
            XCTAssertEqual(r.source,"synthetic"); XCTAssertEqual(r.sourceDirectionStable,false)
            XCTAssertGreaterThan(try XCTUnwrap(r.grid).unknownFraction,0)
            // World vertices must align with their actual source pixels, even as camera pose changes.
            let vertex = try XCTUnwrap(m.triangles.first).a
            let camera = o.pose.camera(vertex),uv = try XCTUnwrap(o.intrinsics.project(camera))
            let u = Int(uv.x.rounded()),v = Int(uv.y.rounded())
            XCTAssertEqual(-camera.z,o.depth[v*o.width+u],accuracy:0.0001)
        }
    }
    func testSteepPitchAndMissingFloorPriorsKeepNewGeometryButNoCandidates() throws {
        let analyzer = SpatialAnalyzer(),p = ProbeParameters()
        for i in 0..<3 {
            let (o,priors) = scene(index:i)
            _ = analyzer.analyze(o,priors:priors,parameters:p,parameterVersion:0,directionStable:true,source:"synthetic")
        }
        for (i,pitch) in [Float(65),85,90].enumerated() {
            let (o,_) = scene(index:i+3,pitchDegrees:pitch)
            let r = analyzer.analyze(o,priors:[],parameters:p,parameterVersion:0,directionStable:false,source:"synthetic")
            let model = try XCTUnwrap(r.surfaceModel)
            XCTAssertGreaterThan(model.summary.groundTriangles,0)
            XCTAssertEqual(r.diagnostics?.groundReferenceMode,"retained_world_reference")
            XCTAssertEqual(r.diagnostics?.groundReference?.frameID,3)
            XCTAssertEqual(r.frameID,o.frameID)
            XCTAssertTrue(r.segments.isEmpty); XCTAssertTrue(r.distances.isEmpty)
            XCTAssertFalse(try XCTUnwrap(r.grid).cells.contains { $0.state == .candidate })
            for t in model.triangles.prefix(50) {
                let camera = o.pose.camera(t.a),uv = try XCTUnwrap(o.intrinsics.project(camera))
                XCTAssertEqual(-camera.z,o.depth[Int(uv.y.rounded())*o.width+Int(uv.x.rounded())],accuracy:0.0001)
            }
        }
        var (expired,_) = scene(index:6,pitchDegrees:85); expired.timestamp = 12.3
        let r = analyzer.analyze(expired,priors:[],parameters:p,parameterVersion:0,directionStable:false,source:"synthetic")
        XCTAssertNil(r.surfaceModel); XCTAssertTrue(r.segments.isEmpty)
    }
    func testReferenceDoesNotInventBlueFloorWhenOnlyAnElevatedSurfaceIsVisible() throws {
        let analyzer = SpatialAnalyzer(),p = ProbeParameters()
        for i in 0..<3 {
            let (o,priors) = scene(index:i)
            _ = analyzer.analyze(o,priors:priors,parameters:p,parameterVersion:0,directionStable:true,source:"synthetic")
        }
        var (o,_) = scene(index:3,pitchDegrees:65)
        // SYNTHETIC: every visible valid ray hits the top of a large 50 cm platform, no ground pixels.
        for v in 0..<o.height { for u in 0..<o.width {
            let ray = o.pose.world(o.intrinsics.unproject(u:Float(u),v:Float(v),depth:1))-o.pose.position
            o.depth[v*o.width+u] = ray.y < 0 ? (0.5-o.pose.position.y)/ray.y : .nan
        }}
        let r = analyzer.analyze(o,priors:[],parameters:p,parameterVersion:0,directionStable:false,source:"synthetic")
        let m = try XCTUnwrap(r.surfaceModel)
        XCTAssertEqual(m.summary.groundTriangles,0); XCTAssertGreaterThan(m.summary.protrusionTriangles,0)
        XCTAssertTrue(r.segments.isEmpty); XCTAssertFalse(try XCTUnwrap(r.grid).cells.contains { $0.state == .candidate })
        analyzer.reset()
        XCTAssertNil(analyzer.analyze(o,priors:[],parameters:p,parameterVersion:0,directionStable:false,source:"synthetic").surfaceModel)
    }
    func testMovingGeometryStillRequiresCurrentDepthAndGroundEvidence() throws {
        let analyzer = SpatialAnalyzer(); let p = ProbeParameters()
        for i in 0..<3 {
            let (o,priors) = scene(index:i)
            _ = analyzer.analyze(o,priors:priors,parameters:p,parameterVersion:0,directionStable:false,source:"synthetic")
        }
        let (removed,priors) = scene(index:3,box:false)
        let r = analyzer.analyze(removed,priors:priors,parameters:p,parameterVersion:0,directionStable:false,source:"synthetic")
        let model = try XCTUnwrap(r.surfaceModel)
        XCTAssertEqual(model.summary.protrusionTriangles,0)
        XCTAssertTrue(try XCTUnwrap(model.blockingVolume).columns.isEmpty)
        let (low,lowPriors) = scene(index:4,confidence:1)
        let noEvidence = analyzer.analyze(low,priors:lowPriors,parameters:p,parameterVersion:0,directionStable:false,source:"synthetic")
        XCTAssertNil(noEvidence.surfaceModel); XCTAssertNil(noEvidence.grid)
        let (unconfirmed,_) = scene(index:5)
        let noFloor = analyzer.analyze(unconfirmed,priors:[],parameters:p,parameterVersion:0,directionStable:false,source:"synthetic")
        // Build 4 retains only the reference plane, using NEW measured depth; guidance stays unknown.
        XCTAssertNotNil(noFloor.surfaceModel); XCTAssertTrue(noFloor.segments.isEmpty)
        XCTAssertEqual(noFloor.diagnostics?.groundReferenceMode,"retained_world_reference")
        XCTAssertFalse(try XCTUnwrap(noFloor.grid).cells.contains { $0.state == .candidate })
    }
}
