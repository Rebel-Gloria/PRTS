import XCTest
import simd
@testable import SpatialCore

final class SurfaceModelTests: XCTestCase {
    // Synthetic pinhole rays: flat ground, optional raised block, far wall. No device data.
    private func scene(blockHeight: Float? = nil,step: Int = 1) -> (DepthObservation,GroundPlane,LocalGrid,ProbeParameters) {
        let k = CameraIntrinsics(fx:100,fy:100,cx:63.5,cy:47.5,width:128,height:96)
        let a: Float = 25 * .pi/180
        let pose = RigidPose(right:V3(1,0,0),up:V3(0,cos(a),-sin(a)),back:V3(0,sin(a),cos(a)),position:V3(0,1.3,0))
        var depths: [Float] = []
        for v in 0..<k.height { for u in 0..<k.width {
            let direction = pose.world(k.unproject(u:Float(u),v:Float(v),depth:1))-pose.position
            var depth: Float = direction.z < 0 ? -5/direction.z : 5
            if direction.y < 0 { depth = min(depth,-pose.position.y/direction.y) }
            if let h = blockHeight,direction.y < 0 {
                let t = (h-pose.position.y)/direction.y
                let p = pose.position+direction*t
                if t > 0,abs(p.x) < 0.45,p.z <= -1.3,p.z >= -2.3 { depth = min(depth,t) }
                if direction.z < 0 {
                    let sideT = -1.3/direction.z,q = pose.position+direction*sideT
                    if sideT > 0,abs(q.x) < 0.45,q.y >= 0,q.y <= h { depth = min(depth,sideT) }
                }
            }
            depths.append(depth)
        }}
        let o = DepthObservation(width:k.width,height:k.height,depth:depths,confidence:Array(repeating:2,count:depths.count),
                                 intrinsics:k,pose:pose,timestamp:10,frameID:20,epoch:2)
        let plane = GroundPlane(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
        var p = ProbeParameters(); p.samplingStep = step
        let basis = GroundBasis(plane:plane,pose:pose)!
        return (o,plane,GridBuilder.build(points:o.points(parameters:p),observation:o,plane:plane,basis:basis,parameters:p),p)
    }
    private func model(_ s: (DepthObservation,GroundPlane,LocalGrid,ProbeParameters)) -> SurfaceModel? {
        SurfaceModelBuilder.build(observation:s.0,plane:s.1,grid:s.2,groundConfirmed:true,parameters:s.3)
    }
    func testFlatGroundBuildsBlueClassAndNoRedClass() throws {
        let s = scene(),m = try XCTUnwrap(model(s))
        XCTAssertGreaterThan(m.summary.groundTriangles,0)
        XCTAssertEqual(m.summary.protrusionTriangles,0)
        XCTAssertTrue(m.triangles.allSatisfy { $0.surface == .ground })
        XCTAssertNil(m.summary.maximumObservedProtrusionHeight)
    }
    func testRaisedObjectBuildsRedActualHeightAndGroundRemainsBlue() throws {
        let s = scene(blockHeight:0.25),m = try XCTUnwrap(model(s))
        XCTAssertGreaterThan(m.summary.groundTriangles,0)
        XCTAssertGreaterThan(m.summary.protrusionTriangles,0)
        XCTAssertEqual(try XCTUnwrap(m.summary.maximumObservedProtrusionHeight),0.25,accuracy:0.001)
        for t in m.triangles {
            for point in [t.a,t.b,t.c] {
                if t.surface == .protrusion { XCTAssertGreaterThanOrEqual(s.1.height(point),m.summary.minimumProtrusionHeight) }
                else { XCTAssertLessThanOrEqual(abs(s.1.height(point)),s.3.planeTolerance) }
            }
        }
        XCTAssertLessThanOrEqual(m.triangles.count,SurfaceModelBuilder.triangleBudget)
    }
    func testUnconfirmedGroundNeverAuthorizesSurfaceColors() {
        let s = scene(blockHeight:0.25)
        XCTAssertNil(SurfaceModelBuilder.build(observation:s.0,plane:s.1,grid:s.2,groundConfirmed:false,parameters:s.3))
        var plane = s.1; plane.floorPriorConfirmed = false
        XCTAssertNil(SurfaceModelBuilder.build(observation:s.0,plane:plane,grid:s.2,groundConfirmed:true,parameters:s.3))
    }
    func testMissingOrLowConfidenceHasNoModelEvidence() throws {
        var s = scene(blockHeight:0.25)
        s.0.confidence = nil
        XCTAssertNil(model(s))
        s.0.confidence = Array(repeating:1,count:s.0.depth.count)
        XCTAssertTrue(try XCTUnwrap(model(s)).triangles.isEmpty)
    }
    func testUncertainFourCentimeterRiseIsNotPaintedAsFloorOrRedModel() throws {
        let s = scene(blockHeight:0.04),m = try XCTUnwrap(model(s))
        XCTAssertEqual(m.summary.protrusionTriangles,0)
        XCTAssertTrue(s.2.cells.contains { $0.state == .obstacle }) // Modeling threshold never erases safety evidence.
        for t in m.triangles {
            XCTAssertTrue([t.a,t.b,t.c].allSatisfy { abs(s.1.height($0)) <= s.3.planeTolerance })
        }
    }
    func testSingleOutlierDoesNotCreateRedSurface() throws {
        var s = scene()
        s.0.depth[50*s.0.width+64] = 0.8
        let basis = GroundBasis(plane:s.1,pose:s.0.pose)!
        s.2 = GridBuilder.build(points:s.0.points(parameters:s.3),observation:s.0,plane:s.1,basis:basis,parameters:s.3)
        XCTAssertEqual(try XCTUnwrap(model(s)).summary.protrusionTriangles,0)
    }
    func testCoarsePatchCannotBridgeUnsampledInvalidPixel() throws {
        var s = scene(step:4)
        let u = 55,v = 49 // Interior pixel, NOT a sampled triangle corner.
        s.0.confidence![v*s.0.width+u] = 0
        let m = try XCTUnwrap(model(s))
        XCTAssertGreaterThan(m.summary.groundTriangles,0)
        for t in m.triangles {
            let uv = [t.a,t.b,t.c].map { s.0.intrinsics.project(s.0.pose.camera($0))! }
            // No triangle may come from the coarse 52...56 by 48...52 patch containing the hole.
            let center = uv.reduce(SIMD2<Float>.zero,+)/3
            XCTAssertFalse(center.x > 52 && center.x < 56 && center.y > 48 && center.y < 52)
        }
    }
    func testDifferentFrameOrEpochCannotReuseSupport() {
        var s = scene(blockHeight:0.25)
        s.2.epoch += 1; XCTAssertNil(model(s))
        s.2.epoch = s.0.epoch; s.2.frameID += 1; XCTAssertNil(model(s))
        s.2.frameID = s.0.frameID; s.2.timestamp -= 0.1; XCTAssertNil(model(s))
    }
    func testHeightUsesTiltedGroundNormalNotWorldY() throws {
        let base = scene(blockHeight:0.25),baseModel = try XCTUnwrap(model(base))
        let a: Float = 7 * .pi/180
        let transform = RigidPose(right:V3(cos(a),sin(a),0),up:V3(-sin(a),cos(a),0),back:V3(0,0,1),position:V3(0,2,0))
        func rotate(_ p: V3) -> V3 { transform.world(p)-transform.position }
        var o = base.0
        o.pose = RigidPose(right:rotate(o.pose.right),up:rotate(o.pose.up),back:rotate(o.pose.back),position:transform.world(o.pose.position))
        let n = rotate(base.1.normal)
        let plane = GroundPlane(normal:n,offset:-simd_dot(n,transform.position),floorPriorConfirmed:true)
        let basis = GroundBasis(plane:plane,pose:o.pose)!
        let grid = GridBuilder.build(points:o.points(parameters:base.3),observation:o,plane:plane,basis:basis,parameters:base.3)
        let m = try XCTUnwrap(model((o,plane,grid,base.3)))
        XCTAssertGreaterThan(m.summary.groundTriangles,0)
        XCTAssertGreaterThan(m.summary.protrusionTriangles,0)
        XCTAssertEqual(try XCTUnwrap(m.summary.maximumObservedProtrusionHeight),0.25,accuracy:0.001)
        XCTAssertEqual(m.summary.protrusionTriangles,baseModel.summary.protrusionTriangles)
    }
    func testFullModelIsCodableButOldAnalysisWithoutModelStillDecodes() throws {
        let m = try XCTUnwrap(model(scene(blockHeight:0.25)))
        let restored = try JSONDecoder().decode(SurfaceModel.self,from:JSONEncoder().encode(m))
        XCTAssertEqual(restored.summary.protrusionTriangles,m.summary.protrusionTriangles)
        var r = AnalysisResult(epoch:1,frameID:1,timestamp:1,parameters:.init(),status:"synthetic",source:"synthetic")
        r.surfaceModel = m
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(r)) as? [String:Any])
        legacy.removeValue(forKey:"surfaceModel")
        let decoded = try JSONDecoder().decode(AnalysisResult.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(decoded.surfaceModel)
    }
}
