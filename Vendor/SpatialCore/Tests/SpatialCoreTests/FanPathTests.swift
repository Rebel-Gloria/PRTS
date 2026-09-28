import XCTest
import simd
@testable import SpatialCore

/// All fixtures are synthetic geometry; these are NOT sensor/real-world clearance measurements.
final class FanPathTests: XCTestCase {
    func grid(halfWidth: Float = 1.5,_ state: (SIMD2<Float>,Int,Int) -> CellState = { _,_,z in z >= 2 ? .candidate : .unknown }) -> LocalGrid {
        let plane = GroundPlane(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
        let basis = GroundBasis(plane:plane,pose:RigidPose(position:V3(0,1.4,0)))!
        var parameters = ProbeParameters();parameters.halfWidth = halfWidth
        var g = LocalGrid(basis:basis,parameters:parameters)
        for i in g.cells.indices { g.cells[i] = .init(state:state(g.center(i),i%g.columns,i/g.columns)) }
        return g
    }
    func search(_ g: LocalGrid,width: Float = 0.5) -> FanPathPlan {
        FanPathSearch.plan(grid:g,mask:PathClearance.mask(grid:g,radius:width/2),width:width)
    }
    func result(_ g: LocalGrid,id: UInt64 = 1,time: Double = 1) -> AnalysisResult {
        var r = AnalysisResult(epoch:1,frameID:id,timestamp:time,parameters:.init(),status:"synthetic",source:"synthetic")
        r.grid = g;r.sourcePose = .init(position:V3(0,1.4,0));r.sourceDirectionStable = true
        r.plane = .init(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
        r.diagnostics = .init();r.diagnostics?.groundReferenceMode = "current_confirmed"
        var triangles: [SurfaceTriangle] = []
        for i in g.cells.indices where g.cells[i].state == .candidate {
            let c = g.center(i),s = g.cellSize/2
            let a = g.basis.world(x:c.x-s,h:0,z:c.y-s),b = g.basis.world(x:c.x+s,h:0,z:c.y-s)
            let d = g.basis.world(x:c.x-s,h:0,z:c.y+s),e = g.basis.world(x:c.x+s,h:0,z:c.y+s)
            triangles += [.init(a:a,b:b,c:d,surface:.ground),.init(a:b,b:e,c:d,surface:.ground)]
        }
        r.surfaceModel = .init(triangles:triangles,summary:.init(groundTriangles:triangles.count,protrusionTriangles:0,minimumProtrusionHeight:0.05,maximumObservedProtrusionHeight:nil,samplingStep:2))
        return r
    }
    func testOldOptionsMigrateWithoutLosingPreferences() throws {
        let data = #"{"enabled":true,"haptics":false,"retentionSeconds":4,"deviationDegrees":18,"lookAhead":1.2}"#.data(using:.utf8)!
        let o = try JSONDecoder().decode(PathOptions.self,from:data)
        XCTAssertEqual(o.minimumWidth,0.5);XCTAssertFalse(o.haptics);XCTAssertEqual(o.retentionSeconds,4)
        XCTAssertEqual(try JSONDecoder().decode(PathOptions.self,from:JSONEncoder().encode(o)),o)
        var invalid = o;invalid.minimumWidth = .nan;XCTAssertEqual(invalid.validated().minimumWidth,0.5)
    }
    func testExactlyHalfMetreFitsButFortyCentimetresDoesNot() {
        let half = grid { _,x,z in z >= 2 && (13...17).contains(x) ? .candidate : .unknown }
        let thin = grid { _,x,z in z >= 2 && (13...16).contains(x) ? .candidate : .unknown }
        XCTAssertEqual(search(half).points.count,2)
        XCTAssertTrue(search(thin).points.isEmpty)
        XCTAssertTrue(search(half,width:0.9).points.isEmpty)
    }
    func testTangentialWallsAgreeWithSweptDiskAndMask() {
        let g = grid(halfWidth:1.55) { _,x,z in
            if x == 12 || x == 18 { return .obstacle }
            return z >= 2 && (13...17).contains(x) ? .candidate : .unknown
        }
        let p = search(g);XCTAssertEqual(p.points.count,2)
        for (a,b) in zip(p.points,p.points.dropFirst()) {
            let aa = g.basis.local(a),bb = g.basis.local(b)
            XCTAssertTrue(PathClearance.segment(grid:g,from:SIMD2(aa.x,aa.z),to:SIMD2(bb.x,bb.z),radius:0.25))
        }
        var predictor = PathPredictor()
        let first = predictor.update(result:result(g),observation:nil,options:.init())
        let next = predictor.update(result:result(g,id:2,time:1.1),observation:nil,options:.init())
        XCTAssertNotNil(first.path);XCTAssertEqual(next.reason,"revalidated_world_path")
        XCTAssertEqual(first.path?.id,next.path?.id)
    }
    func testFarthestRadialTargetAndSimplification() {
        let g = grid(),p = search(g)
        XCTAssertEqual(p.points.count,2);XCTAssertGreaterThan(p.reachableCells,100)
        XCTAssertEqual(g.basis.local(p.points.last!).z,3.75,accuracy:0.001)
        XCTAssertGreaterThan(abs(p.targetBearingDegrees ?? 0),15)
        XCTAssertGreaterThan(p.approachDistance ?? 0,0.3)
    }
    func testNoTargetOutsideFortyFiveDegreeFan() {
        let onlySide = grid { p,_,_ in p.x > p.y+0.1 ? .candidate : .unknown }
        XCTAssertTrue(search(onlySide).points.isEmpty)
        let g = grid(),p = search(g)
        for point in p.points { let q = g.basis.local(point);XCTAssertLessThanOrEqual(abs(q.x),q.z+0.0001) }
    }
    func testFartherSideWinsWithoutFrontPreference() {
        let g = grid { p,_,z in
            if z < 2 { return .unknown }
            // The farther side wins; there is deliberately no central-angle preference.
            return p.y < 3.7 || p.x > 0.8 ? .candidate : .unknown
        }
        let p = search(g)
        XCTAssertGreaterThan(p.targetDistance ?? 0,3.3)
        XCTAssertGreaterThan(abs(p.targetBearingDegrees ?? 0),15)
    }
    func testSidewaysDetourKeepsSweptFootprintOutOfObstacle() {
        let g = grid { p,_,z in
            if z < 2 { return .unknown }
            return abs(p.x) < 0.35 && p.y > 1.2 && p.y < 2.5 ? .obstacle : .candidate
        }
        let p = search(g);XCTAssertGreaterThan(p.points.count,1)
        XCTAssertGreaterThan(g.basis.local(p.points.last!).z,3.4)
        XCTAssertTrue(p.points.contains{abs(g.basis.local($0).x)>0.5})
        for (a,b) in zip(p.points,p.points.dropFirst()) {
            let aa = g.basis.local(a),bb = g.basis.local(b)
            XCTAssertTrue(PathClearance.segment(grid:g,from:SIMD2(aa.x,aa.z),to:SIMD2(bb.x,bb.z),radius:0.25))
        }
    }
    func testCannotBridgeUnknownStripeWithObservedSolidLine() {
        let g = grid { p,_,z in z < 2 || (p.y > 1.8 && p.y < 2.2) ? .unknown : .candidate }
        let p = search(g);XCTAssertFalse(p.points.isEmpty)
        XCTAssertLessThan(p.points.map{g.basis.local($0).z}.max()!,1.8)
    }
    func testKnownObstacleBlocksEvenDashedApproach() {
        let g = grid { p,_,_ in p.y < 1 ? .obstacle : .candidate }
        XCTAssertTrue(search(g).points.isEmpty)
        XCTAssertFalse(PathClearance.segment(grid:g,from:.zero,to:SIMD2(0,2),radius:0.25,allowUnknown:true))
    }
    func testUnknownApproachIsSeparateAndDoesNotPromoteGrid() {
        let g = grid { p,_,_ in p.y >= 1 ? .candidate : .unknown },r = result(g)
        var predictor = PathPredictor();let path = predictor.update(result:r,observation:nil,options:.init()).path!
        var gate = ResultPresentationGate();gate.enabled = true;gate.trackingNormal = true
        gate.epoch = 1;gate.frameID = 1;gate.frameTimestamp = 1
        let presentation = PathPresentation.make(path:path,gate:gate,pose:r.sourcePose!,options:.init(),now:1)!
        XCTAssertEqual(presentation.approach.count,2)
        XCTAssertEqual(presentation.approach[0],V3.zero)
        XCTAssertEqual(presentation.approach.last,path.points.first)
        XCTAssertGreaterThan(g.basis.local(path.points[0]).z,1)
        XCTAssertEqual(r.grid!.cells[0].state,.unknown)
        XCTAssertEqual(r.segments.count,0)
    }
    func testNewObstacleInFootApproachInvalidatesRetainedPath() {
        let g = grid { p,_,_ in p.y >= 1 ? .candidate : .unknown }
        var predictor = PathPredictor()
        XCTAssertNotNil(predictor.update(result:result(g),observation:nil,options:.init()).path)
        let blocked = grid { p,_,_ in p.y > 0.4 && p.y < 0.7 ? .obstacle : .unknown }
        var r = result(blocked,id:2,time:1.1);r.surfaceModel = nil
        let update = predictor.update(result:r,observation:nil,options:.init())
        XCTAssertNil(update.path);XCTAssertEqual(update.reason,"current_obstacle_invalidated")
    }
    func testWidthIncreaseImmediatelyHidesOldPathAndInvalidatesCache() {
        let g = grid { _,x,z in z >= 2 && (13...17).contains(x) ? .candidate : .unknown }
        var predictor = PathPredictor();let r = result(g),path = predictor.update(result:r,observation:nil,options:.init()).path!
        var gate = ResultPresentationGate();gate.enabled = true;gate.trackingNormal = true
        gate.epoch = 1;gate.frameID = 1;gate.frameTimestamp = 1
        var wide = PathOptions();wide.minimumWidth = 0.8
        XCTAssertNil(PathPresentation.make(path:path,gate:gate,pose:r.sourcePose!,options:wide,now:1))
        XCTAssertNil(predictor.update(result:result(g,id:2,time:1.1),observation:nil,options:wide).path)
    }
    func testDrawingHasMetricDashesAndGoalAtObservedEndpoint() {
        let g = grid();var predictor = PathPredictor()
        let path = predictor.update(result:result(g),observation:nil,options:.init()).path!
        let p = PathPresentation(path:path,age:1,historical:true,approach:[.zero,path.points[0]])
        let meshes = PathDrawing.meshes(p)
        let history = meshes.first{$0.role == .history}!.vertices
        XCTAssertGreaterThan(history.count,12) // A two-point path must still have many metric dashes.
        let drawnLength = stride(from:0,to:history.count,by:6).reduce(Float(0)) { $0+simd_distance(history[$1],history[$1+2]) }
        XCTAssertLessThan(drawnLength,path.length*0.7);XCTAssertGreaterThan(drawnLength,path.length*0.5)
        let ring = meshes.first{$0.role == .target}!.vertices
        XCTAssertEqual(ring.count,144)
        let center = ring.reduce(V3.zero,+)/Float(ring.count)
        XCTAssertLessThan(simd_distance(center,path.points.last!+V3(0,0.025,0)),0.0001)
        XCTAssertFalse(meshes.first{$0.role == .unknownApproach}!.vertices.isEmpty)
    }
    func testStringPullCannotCutUnknownCorner() {
        let g = grid { p,_,_ in p.x < 0 && p.y < 2 ? .unknown : .candidate }
        XCTAssertFalse(PathClearance.segment(grid:g,from:SIMD2(-0.6,2.4),to:SIMD2(0.6,1.4),radius:0.25))
        XCTAssertTrue(PathClearance.segment(grid:g,from:SIMD2(0.6,2.4),to:SIMD2(0.6,1.4),radius:0.25))
    }
}
