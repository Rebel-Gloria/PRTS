import XCTest
import simd
@testable import SpatialCore

final class GroundRouteDrawingTests: XCTestCase {
    func presentation(_ points:[V3],approach:[V3]=[],width:Float=0.6)->PathPresentation {
        let path=PredictedPath(id:1,epoch:1,parameterVersion:0,sourceFrameID:1,validatedFrameID:1,
            observedAt:1,plane:.init(normal:V3(0,1,0),offset:0),points:points,source:"test",
            requiredWidth:width,planningPolicy:.obstacleVeto,worldLocked:true)
        return .init(path:path,age:0,historical:false,approach:approach)
    }
    func testNearestEntryProjectionRemovesHookWithoutChangingPlan() {
        let points=[V3.zero,V3(0,0,-2)],foot=V3(0,0,-0.3)
        let p=presentation(points,approach:[foot,.zero])
        let shape=GroundRouteDrawing.make(p,obstacles:[])
        XCTAssertEqual(shape.points,[foot,V3(0,0,-2)])
        XCTAssertEqual(p.path.points,points)
        XCTAssertFalse(shape.usedFallback)
    }
    func testMissingModelAndFailedCollisionStillDrawOriginalPolyline() {
        let p=presentation([V3(-1,0,0),.zero,V3(0,0,-1)])
        let wall=OccupancyFootprint(center:.zero,right:V3(1,0,0),forward:V3(0,0,1),size:4)
        for model:[OccupancyFootprint]? in [nil,[wall]] {
            let shape=GroundRouteDrawing.make(p,obstacles:model)
            XCTAssertTrue(shape.usedFallback)
            XCTAssertEqual(shape.points,p.path.points)
            XCTAssertTrue(PathDrawing.meshes(p,obstacles:model).contains{$0.role == .planned && !$0.vertices.isEmpty})
        }
    }
    func testEveryFinalChordIsCheckedAndRoundJoinIsFinite() {
        let p=presentation([V3(-1,0,0),.zero,V3(0,0,-1)],width:0.02)
        let obstacle=OccupancyFootprint(center:V3(-0.03,0,-0.03),right:V3(1,0,0),forward:V3(0,0,1),size:0.004)
        let rounded=GroundRouteDrawing.rounded(p.path.points,trim:0.12)
        XCTAssertTrue(zip(rounded,rounded.dropFirst()).contains{obstacle.overlaps(from:$0,to:$1,radius:0.011)})
        let smaller=OccupancyFootprint(center:V3(-0.015,0,-0.015),right:V3(1,0,0),forward:V3(0,0,1),size:0.004)
        let shape=GroundRouteDrawing.make(p,obstacles:[obstacle,smaller])
        XCTAssertTrue(shape.usedFallback)
        XCTAssertEqual(shape.points,p.path.points) // Both radii fail: exactly the original polyline.
        XCTAssertFalse(zip(shape.points,shape.points.dropFirst()).contains{a,b in
            [obstacle,smaller].contains{$0.overlaps(from:a,to:b,radius:0.011)}
        })
        let mesh=PathDrawing.meshes(p,obstacles:nil).first{$0.role == .planned}!.vertices
        XCTAssertGreaterThan(mesh.count,12) // The original two ribbons now have a round seam.
        XCTAssertTrue(mesh.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.z.isFinite})
    }
    func testHeightFollowsPlanningLocalGroundAndDeviationFailureFallsBack() {
        var p=presentation([V3(-1,0,0),.zero,V3(0,0,-1)],approach:[V3(0.5,0,0.5),V3(-1,0,0)])
        p.path.plane = .init(normal:V3(0,1,0),offset:-0.2)
        p.path.points=p.path.points.map{V3($0.x,0.2,$0.z)}
        p.approach=p.approach.map{V3($0.x,0.2,$0.z)}
        let shape=GroundRouteDrawing.make(p,obstacles:[])
        XCTAssertTrue(shape.usedFallback)
        XCTAssertEqual(shape.points,Array(p.approach.dropLast())+p.path.points)
        XCTAssertTrue(shape.points.allSatisfy{abs(p.path.plane.height($0))<0.00001})
    }
}
