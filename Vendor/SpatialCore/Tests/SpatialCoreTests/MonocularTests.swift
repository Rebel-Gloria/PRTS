import XCTest
import simd
@testable import SpatialCore

/// All observations here are synthetic; none constitute physical sensor validation.
final class MonocularTests: XCTestCase {
    func testNoHardwareForcesModeAndLocksSwitch() {
        for requested in [false,true] { let p = DepthBackendPolicy(supportsSceneDepth:false,requestedSimulation:requested); XCTAssertTrue(p.usesMonocular); XCTAssertFalse(p.switchEnabled) }
    }
    func testHardwareCanSwitchBothWays() {
        var p = DepthBackendPolicy(supportsSceneDepth:true,requestedSimulation:false)
        XCTAssertFalse(p.usesMonocular); XCTAssertTrue(p.switchEnabled)
        p.requestedSimulation = true; XCTAssertTrue(p.usesMonocular)
        p.requestedSimulation = false; XCTAssertFalse(p.usesMonocular)
    }
    func testCompleteViewMappingEveryOrientationAndDifferentResolution() {
        for orientation in ImageOrientation.allCases {
            let m = ModelImageMapping(width:1920,height:1440,modelWidth:518,modelHeight:392,orientation:orientation)
            let center = m.modelPixel(u:959.5,v:719.5)
            XCTAssertEqual(center.x,258.5,accuracy:0.0001); XCTAssertEqual(center.y,195.5,accuracy:0.0001)
            for v: Float in [-0.5,1439.5] { for u: Float in [-0.5,1919.5] {
                let p = m.modelPixel(u:u,v:v)
                XCTAssertGreaterThanOrEqual(p.x+0.5001,m.fit.x); XCTAssertLessThanOrEqual(p.x+0.4999,m.fit.x+m.fit.width)
                XCTAssertGreaterThanOrEqual(p.y+0.5001,m.fit.y); XCTAssertLessThanOrEqual(p.y+0.4999,m.fit.y+m.fit.height)
                let mappedUV = SIMD2((p.x+0.5-m.fit.x)/m.fit.width,(p.y+0.5-m.fit.y)/m.fit.height)
                let raw = orientation.imageUV(mappedUV)
                XCTAssertEqual(raw.x,(u+0.5)/1920,accuracy:0.00001); XCTAssertEqual(raw.y,(v+0.5)/1440,accuracy:0.00001)
            }}
        }
    }
    private func samples() -> [ScaleSample] {
        (0..<64).map { i in
            let z = Float(0.6)+Float(i)*0.055
            return .init(relative:(1/z-0.1)/0.06,meters:z,u:Float(i%8)/8+0.03,v:Float(i/8)/8+0.03,source:"synthetic_metric_reference")
        }
    }
    func testRecoversAffineInverseDepthWithShiftNotJustScale() throws {
        let c = try XCTUnwrap(InverseDepthCalibration.fit(samples()))
        for s in samples() { XCTAssertEqual(try XCTUnwrap(c.meters(s.relative)),s.meters,accuracy:0.001) }
        XCTAssertEqual(c.samples,64); XCTAssertEqual(c.inliers,64)
    }
    func testRejectsOutliersAndNonFiniteSamples() throws {
        var s = samples()
        for i in stride(from:0,to:64,by:7) { s[i] = .init(relative:s[i].relative,meters:7,u:s[i].u,v:s[i].v,source:"synthetic_outlier") }
        s.append(.init(relative:.nan,meters:2,u:0.2,v:0.3,source:"synthetic_invalid"))
        let c = try XCTUnwrap(InverseDepthCalibration.fit(s))
        XCTAssertLessThan(c.inliers,64); XCTAssertEqual(try XCTUnwrap(c.meters((1/Float(2)-0.1)/0.06)),2,accuracy:0.04)
    }
    func testRejectsConstantRelativeOrDepthAndSparseOrNarrowSupport() {
        XCTAssertNil(InverseDepthCalibration.fit(Array(samples().prefix(10))))
        XCTAssertNil(InverseDepthCalibration.fit(samples().map { .init(relative:1,meters:$0.meters,u:$0.u,v:$0.v,source:$0.source) }))
        XCTAssertNil(InverseDepthCalibration.fit(samples().map { .init(relative:$0.relative,meters:2,u:$0.u,v:$0.v,source:$0.source) }))
        XCTAssertNil(InverseDepthCalibration.fit(samples().map { .init(relative:$0.relative,meters:$0.meters,u:0.1,v:0.1,source:$0.source) }))
    }
    func testRejectsWrongDepthConventionAndUnboundedExtrapolation() throws {
        XCTAssertNil(InverseDepthCalibration.fit(samples().map { .init(relative:-$0.relative,meters:$0.meters,u:$0.u,v:$0.v,source:$0.source) }))
        let c = try XCTUnwrap(InverseDepthCalibration.fit(samples()))
        XCTAssertNil(c.meters(c.maximum+100)); XCTAssertNil(c.meters(.nan))
    }
    private func plane(_ classification: String = "floor", y: Float = 0,time: Double = 1) -> NativePlaneObservation {
        .init(id:classification,classification:classification,pose:.init(position:V3(0,y,0)),boundary:[V3(-2,0,-4),V3(2,0,-4),V3(2,0,0),V3(-2,0,0)],timestamp:time)
    }
    func testNativePlaneBoundaryDoesNotBecomeInfiniteFloor() {
        let p = plane(); XCTAssertEqual(p.area,16,accuracy:0.001)
        XCTAssertTrue(p.contains(V3(0,0,-2))); XCTAssertFalse(p.contains(V3(3,0,-2)))
        let k = CameraIntrinsics(fx:100,fy:100,cx:50,cy:50,width:100,height:100)
        XCTAssertNotNil(p.rayDepth(u:50,v:95,intrinsics:k,camera:.init(position:V3(0,1.3,0))))
        XCTAssertNil(p.rayDepth(u:50,v:50,intrinsics:k,camera:.init(position:V3(0,1.3,0))))
    }
    func testNativeGroundRequiresStabilityAndRejectsTablesAndOldObservation() {
        var tracker = NativeGroundTracker(); let camera = RigidPose(position:V3(0,1.3,0))
        XCTAssertNil(tracker.select([plane()],camera:camera,time:1))
        XCTAssertNotNil(tracker.select([plane(time:1.5)],camera:camera,time:1.5))
        XCTAssertNil(tracker.select([plane(time:1.5)],camera:camera,time:2))
        XCTAssertNil(tracker.select([plane("table",y:0.6,time:2)],camera:camera,time:2))
        XCTAssertNil(tracker.select([plane("table",y:0.6,time:3)],camera:camera,time:3))
    }
    func testUnknownPlaneNeverGainsFloorClassificationAndResetDropsStability() throws {
        var tracker = NativeGroundTracker(); let camera = RigidPose(position:V3(0,1.3,0))
        _ = tracker.select([plane("unknown")],camera:camera,time:1)
        let p = try XCTUnwrap(tracker.select([plane("unknown",time:1.5)],camera:camera,time:1.5))
        XCTAssertFalse(p.ground.floorPriorConfirmed)
        tracker.reset(); XCTAssertNil(tracker.select([plane("unknown",time:1.6)],camera:camera,time:1.6))
    }
    private func predicted() -> DepthObservation {
        let k = CameraIntrinsics(fx:100,fy:100,cx:63.5,cy:47.5,width:128,height:96)
        let a: Float = 25 * .pi/180
        let pose = RigidPose(right:V3(1,0,0),up:V3(0,cos(a),-sin(a)),back:V3(0,sin(a),cos(a)),position:V3(0,1.3,0))
        var depths: [Float] = []
        for v in 0..<96 { for u in 0..<128 {
            let d = pose.world(k.unproject(u:Float(u),v:Float(v),depth:1))-pose.position
            var z: Float = d.y < 0 ? min(5,-1.3/d.y) : 5
            if d.y < 0 { let t = (Float(0.25)-1.3)/d.y,point = pose.position+d*t
                if abs(point.x) < 0.4,point.z < -1.3,point.z > -2.3 { z = min(z,t) }
            }
            depths.append(z)
        }}
        var o = DepthObservation(width:128,height:96,depth:depths,confidence:nil,intrinsics:k,pose:pose,timestamp:1,frameID:1,epoch:1)
        o.predictionSupport = Array(repeating:1,count:depths.count); return o
    }
    func testPredictionSupportIsNotConfidenceOrFreeSpace() {
        let o = predicted(); XCTAssertNil(o.confidence); XCTAssertTrue(o.valid(100,parameters:.init()))
        XCTAssertFalse(VisibilityDepth(o,parameters:.init()).isClear(corners:Array(repeating:.zero,count:8),margin:0))
        let stats = DepthStatistics(o,parameters:.init()); XCTAssertEqual(stats.acceptedHighConfidence,0); XCTAssertGreaterThan(stats.acceptedPredictionSupport ?? 0,0)
    }
    func testPredictedBlueRedGeometryNeverCreatesCandidateCellsDistancesOrRoutes() throws {
        let o = predicted(),r = PredictedGeometry.analyze(o,ground:plane(),parameters:.init(),parameterVersion:1)
        let m = try XCTUnwrap(r.surfaceModel)
        XCTAssertGreaterThan(m.summary.groundTriangles,0); XCTAssertGreaterThan(m.summary.protrusionTriangles,0)
        XCTAssertTrue(r.segments.isEmpty); XCTAssertTrue(r.distances.isEmpty); XCTAssertFalse(r.footprintMask.contains(true))
        XCTAssertFalse(try XCTUnwrap(r.grid).cells.contains { $0.state == .candidate })
        XCTAssertFalse(r.sourceDirectionStable ?? true)
    }
    func testPredictionWithoutGroundAndMalformedSupportCannotCreateGeometry() {
        var o = predicted()
        XCTAssertNil(PredictedGeometry.analyze(o,ground:nil,parameters:.init(),parameterVersion:1).surfaceModel)
        o.predictionSupport = [1]
        XCTAssertFalse(o.structurallyValid)
        XCTAssertNil(PredictedGeometry.analyze(o,ground:plane(),parameters:.init(),parameterVersion:1).surfaceModel)
    }
    func testRetainedNativeReferenceUsesCurrentPredictionButNeverClearance() throws {
        let o = predicted(),g = plane()
        let r = PredictedGeometry.analyze(o,ground:g,parameters:.init(),parameterVersion:1,
            groundReference:.init(plane:g,mode:"retained_reference",age:0.6,reason:"synthetic_missing_snapshot"))
        XCTAssertNotNil(r.surfaceModel); XCTAssertEqual(r.diagnostics?.groundReferenceMode,"retained_native_reference")
        XCTAssertEqual(r.diagnostics?.groundReferenceAge,0.6)
        XCTAssertTrue(r.segments.isEmpty); XCTAssertTrue(r.distances.isEmpty)
        XCTAssertFalse(try XCTUnwrap(r.grid).cells.contains { $0.state == .candidate })
        XCTAssertNotNil(r.stageMilliseconds["surfaceModel"])
    }
    func testRetainedNativeReferenceExpirationUsesDisplayClockAndNeverAuthorizesGuidance() {
        let o = predicted(),g = plane()
        let r = PredictedGeometry.analyze(o,ground:g,parameters:.init(),parameterVersion:1,
            groundReference:.init(plane:g,mode:"retained_reference",age:1.9,reason:"synthetic_missing_snapshot"))
        var gate = ResultPresentationGate(); gate.enabled = true; gate.trackingNormal = true; gate.directionStable = true
        gate.epoch = o.epoch; gate.parameterVersion = 1; gate.frameID = o.frameID; gate.frameTimestamp = 1.05
        XCTAssertTrue(gate.allowsGeometry(r,now:1.05))
        XCTAssertEqual(gate.guidanceBlockReason(r,now:1.05),"retained_ground_is_not_current_clearance")
        XCTAssertEqual(gate.geometryBlockReason(r,now:1.11),"native_ground_reference_expired")
    }
    func testScaleConflictClearsHistoricalPredictionRatherThanShowingWrongWireframe() {
        let o = predicted()
        let r = PredictedGeometry.analyze(o,ground:plane(),parameters:.init(),parameterVersion:1)
        var history = SurfaceHistory(); history.ingest(r)
        var gate = ResultPresentationGate(); gate.enabled = true; gate.trackingNormal = true
        gate.epoch = o.epoch; gate.parameterVersion = 1; gate.frameID = 2; gate.frameTimestamp = 1.1
        XCTAssertNotNil(history.presentation(current:nil,gate:gate,pose:o.pose,now:1.1))
        var conflict = AnalysisResult(epoch:o.epoch,frameID:2,timestamp:1.1,parameters:.init(),parameterVersion:1,status:"synthetic scale conflict")
        conflict.diagnostics = .init(); conflict.diagnostics?.groundReferenceInvalidation = "metric_world_reference_conflict"
        history.ingest(conflict)
        XCTAssertNil(history.presentation(current:nil,gate:gate,pose:o.pose,now:1.1))
    }
    func testPredictionLogPreservesSeparateMaskNotHardwareConfidence() throws {
        let o = predicted(),data = try DepthFrameCodec.encode(o,parameters:.init(),parameterVersion:1,priors:[],directionStable:false,source:"synthetic_prediction")
        let size = Int(data.withUnsafeBytes { $0.loadUnaligned(as:UInt32.self).littleEndian })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:data[4..<4+size]) as? [String:Any])
        XCTAssertEqual(json["confidenceBytes"] as? Int,0); XCTAssertEqual(json["predictionSupportBytes"] as? Int,o.depth.count)
        XCTAssertEqual(json["depthEvidence"] as? String,"model_prediction_arkit_aligned_not_sensor_confidence")
        XCTAssertEqual(data.count,4+size+o.depth.count*5)
    }
}
