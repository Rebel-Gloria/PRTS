import XCTest
import simd
@testable import SpatialCore

/// Synthetic planar scene with native metric points. NOT physical sensor validation.
final class MetricScaleTrackingTests: XCTestCase {
    let k = CameraIntrinsics(fx:65,fy:65,cx:39.5,cy:31.5,width:80,height:64)
    private func frame(_ time: Double,scale: Float = 1,shift: Float = 0,pose: RigidPose = .init(),
                       metricFactor: Float = 1,epoch: UInt64 = 1,version: UInt64 = 1,
                       orientation: ImageOrientation = .portrait,ids: Bool = true,invalidRaw: Bool = false) throws -> MetricScaleFrame {
        let n = V3(0.4,-0.3,1)
        func depth(_ u: Float,_ v: Float,_ camera: RigidPose) -> Float {
            let ray = camera.world(k.unproject(u:u,v:v,depth:1))-camera.position
            return -(simd_dot(n,camera.position)+3)/simd_dot(n,ray)
        }
        var raw: [Float] = []
        for y in 0..<k.height { for x in 0..<k.width { raw.append(scale/(depth(Float(x),Float(y),pose)*metricFactor)+shift) } }
        var samples: [ScaleSample] = []
        for y in stride(from:5,to:60,by:7) { for x in stride(from:5,to:76,by:8) {
            let world = k.unproject(u:Float(x),v:Float(y),depth:depth(Float(x),Float(y),.init()))*metricFactor
            let p = pose.camera(world)
            guard let uv = k.project(p),uv.x >= 1,uv.y >= 1,uv.x < 78,uv.y < 62 else { continue }
            samples.append(.init(relative:raw[Int(uv.y.rounded())*k.width+Int(uv.x.rounded())],meters:-p.z,u:uv.x/Float(k.width),v:uv.y/Float(k.height),source:"synthetic_native_point",featureID:ids ? UInt64(y*k.width+x) : nil))
        }}
        return .init(timestamp:time,epoch:epoch,parameterVersion:version,orientation:orientation,intrinsics:k,pose:pose,relative:invalidRaw ? Array(repeating:.nan,count:raw.count) : raw,samples:samples,fit:try XCTUnwrap(InverseDepthCalibration.fit(samples)))
    }
    func testAffineRelativeNormalizationChangesDoNotResetPhysicalConfirmation() throws {
        var t = MetricScaleTracker()
        XCTAssertEqual(t.update(try frame(1)).confirmations,1)
        XCTAssertEqual(t.update(try frame(1.1,scale:4,shift:2)).confirmations,2)
        let d = t.update(try frame(1.2,scale:0.2,shift:8))
        XCTAssertEqual(d.confirmations,3); XCTAssertNotNil(d.calibration)
        XCTAssertGreaterThanOrEqual(d.inliers,16); XCTAssertGreaterThanOrEqual(d.matchingFeatureIDs,16)
        XCTAssertLessThan(d.medianRelativeError ?? 1,0.01)
    }
    func testCameraMotionUsesWorldReprojectionNotSameScreenPixel() throws {
        var t = MetricScaleTracker(); _ = t.update(try frame(1))
        let d = t.update(try frame(1.1,scale:0.4,shift:3,pose:.init(position:V3(0.1,0,-0.1))))
        XCTAssertEqual(d.confirmations,2); XCTAssertGreaterThan(d.matchingFeatureIDs,16)
        XCTAssertLessThan(d.medianRelativeError ?? 1,0.02)
    }
    func testLegacyNoIDLogsUseWorldReprojection() throws {
        var t = MetricScaleTracker(); _ = t.update(try frame(1,ids:false))
        let d = t.update(try frame(1.1,scale:3,shift:1,pose:.init(position:V3(0.05,0,0)),ids:false))
        XCTAssertEqual(d.confirmations,2); XCTAssertEqual(d.matchingFeatureIDs,0)
    }
    func testRealMetricScaleConflictStillRejectsEvenWithGoodIndividualFit() throws {
        var t = MetricScaleTracker(); _ = t.update(try frame(1)); _ = t.update(try frame(1.1))
        let d = t.update(try frame(1.2,metricFactor:1.6))
        XCTAssertNil(d.calibration); XCTAssertEqual(d.confirmations,1); XCTAssertGreaterThan(d.referenceConflicts,16); XCTAssertTrue(d.invalidatesHistory)
    }
    func testOcclusionOrNewGeometryCannotMasqueradeAsConsistentScaleWithoutIDs() throws {
        var t = MetricScaleTracker(); _ = t.update(try frame(1,ids:false)); _ = t.update(try frame(1.1,ids:false))
        let d = t.update(try frame(1.2,metricFactor:0.55,ids:false))
        XCTAssertNil(d.calibration); XCTAssertEqual(d.confirmations,1); XCTAssertTrue(d.invalidatesHistory)
    }
    func testNoCurrentFitNeverReusesPreviousCoefficients() throws {
        var t = MetricScaleTracker(); for i in 0..<3 { _ = t.update(try frame(1+Double(i)/10)) }
        let f = try frame(1.3)
        let missing = MetricScaleFrame(timestamp:f.timestamp,epoch:1,parameterVersion:1,orientation:f.orientation,intrinsics:k,pose:f.pose,relative:f.relative,samples:[],fit:nil)
        XCTAssertNil(t.update(missing).calibration)
        XCTAssertEqual(t.update(try frame(1.4)).confirmations,1)
    }
    func testSessionVersionOrientationAndTimeBarriersRequireReconfirmation() throws {
        let cases = [try frame(1.2,epoch:2),try frame(1.2,version:2),try frame(1.2,orientation:.landscapeLeft),try frame(2),try frame(1),try frame(0.9)]
        for next in cases {
            var t = MetricScaleTracker(); _ = t.update(try frame(1)); _ = t.update(try frame(1.1))
            let d = t.update(next); XCTAssertEqual(d.confirmations,1); XCTAssertNil(d.calibration)
        }
    }
    func testResetForBriefUnprocessedTrackingLossClearsConfirmation() throws {
        var t = MetricScaleTracker(); _ = t.update(try frame(1)); _ = t.update(try frame(1.1)); t.reset()
        XCTAssertEqual(t.update(try frame(1.2)).confirmations,1)
    }
    func testMissingCurrentPixelSupportDoesNotAuthorizeMap() throws {
        var t = MetricScaleTracker(); _ = t.update(try frame(1)); _ = t.update(try frame(1.1))
        let d = t.update(try frame(1.2,invalidRaw:true))
        XCTAssertNil(d.calibration); XCTAssertEqual(d.inliers,0)
    }
    func testRangeChangeOnlyDiscardsUnsupportedReferencesWhenOthersAreDistributed() throws {
        let old = try frame(1)
        var fit = try XCTUnwrap(old.fit); fit.minimum += (fit.maximum-fit.minimum)*0.08
        let narrow = MetricScaleFrame(timestamp:1.1,epoch:1,parameterVersion:1,orientation:.portrait,intrinsics:k,pose:old.pose,relative:old.relative,samples:old.samples,fit:fit)
        var t = MetricScaleTracker(); _ = t.update(old)
        let d = t.update(narrow); XCTAssertEqual(d.confirmations,2)
    }
    func testRepeatedPixelCannotInflateTemporalSupport() throws {
        let f = try frame(1)
        let duplicate = MetricScaleFrame(timestamp:1,epoch:1,parameterVersion:1,orientation:.portrait,intrinsics:k,pose:f.pose,relative:f.relative,samples:Array(repeating:f.samples[0],count:100),fit:f.fit)
        var t = MetricScaleTracker(); _ = t.update(duplicate)
        let d = t.update(try frame(1.1)); XCTAssertNil(d.calibration); XCTAssertLessThanOrEqual(d.evaluatedReferences,1)
    }
    func testOldScaleSampleDecodesWithoutInventedFeatureID() throws {
        let old = Data(#"{"relative":0.2,"meters":2,"u":0.3,"v":0.4,"source":"legacy"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ScaleSample.self,from:old).featureID)
    }
}

final class NativeGroundRetentionTests: XCTestCase {
    let camera = RigidPose(position:V3(0,1.3,0))
    func plane(_ t: Double,id: String = "floor",classification: String = "floor",height: Float = 0) -> NativePlaneObservation {
        .init(id:id,classification:classification,pose:.init(position:V3(0,height,0)),boundary:[V3(-2,0,-4),V3(2,0,-4),V3(2,0,0),V3(-2,0,0)],timestamp:t)
    }
    func initialized() -> NativeGroundTracker {
        var t = NativeGroundTracker(); _ = t.update([plane(1)],camera:camera,time:1)
        XCTAssertEqual(t.update([plane(1.5)],camera:camera,time:1.5).mode,"confirmed"); return t
    }
    func testShortMissingSnapshotRetainsReferenceButNotFreshScaleSamples() {
        var t = initialized(); let r = t.update([],camera:camera,time:1.7)
        XCTAssertEqual(r.mode,"retained_reference"); XCTAssertEqual(r.age,0.2,accuracy:0.0001)
        XCTAssertEqual(r.plane?.timestamp,1.5); XCTAssertFalse(r.canSupplyScaleSamples)
        XCTAssertFalse(try! XCTUnwrap(r.plane).contains(V3(5,0,-2)))
    }
    func testRetentionDoesNotRefreshItsOwnDeadline() {
        var t = initialized(); XCTAssertNotNil(t.update([],camera:camera,time:3.4).plane)
        XCTAssertNil(t.update([],camera:camera,time:3.51).plane)
    }
    func testLargeTranslationNormalDisplacementAndFutureTimeInvalidate() {
        for (pose,time) in [(RigidPose(position:V3(1.1,1.3,0)),1.7),(RigidPose(position:V3(0,1.7,0)),1.7),(camera,1.4)] {
            var t = initialized(); XCTAssertNil(t.update([],camera:pose,time:time).plane)
        }
    }
    func testKnownTableReclassificationImmediatelyInvalidatesRetainedFloor() {
        var t = initialized()
        let r = t.update([plane(1.7,classification:"table")],camera:camera,time:1.7)
        XCTAssertNil(r.plane); XCTAssertEqual(r.reason,"native_ground_conflict")
    }
    func testConflictingPlaneOrReplacementDoesNotRetainOldGroundWhileReconfirming() {
        for p in [plane(1.7,height:0.2),plane(1.7,id:"replacement")] {
            var t = initialized(); let r = t.update([p],camera:camera,time:1.7)
            XCTAssertNil(r.plane); XCTAssertEqual(r.mode,"provisional")
        }
    }
    func testUnknownPlaneStaysProvisionalAndCannotCalibrate() {
        var t = NativeGroundTracker(); _ = t.update([plane(1,classification:"unknown")],camera:camera,time:1)
        let r = t.update([plane(1.5,classification:"unknown")],camera:camera,time:1.5)
        XCTAssertEqual(r.mode,"provisional_ground"); XCTAssertFalse(r.canSupplyScaleSamples)
    }
    func testResetClearsRetainedPlane() {
        var t = initialized(); t.reset(); XCTAssertNil(t.update([],camera:camera,time:1.6).plane)
    }
}
