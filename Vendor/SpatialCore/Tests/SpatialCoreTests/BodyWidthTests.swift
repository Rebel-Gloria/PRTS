import XCTest
import simd
@testable import SpatialCore

final class BodyWidthTests: XCTestCase {
    let fixture = ForwardRouteTests()
    func testBalancedDefaultIsHalfMetre() {
        XCTAssertEqual(ProbeParameters().bodyWidth,0.5)
    }
    func testStoredHalfMetreCannotShrinkConfiguredBody() throws {
        let options = try JSONDecoder().decode(PathOptions.self,from:Data(#"{"minimumWidth":0.5}"#.utf8))
        var wide = ProbeParameters();wide.bodyWidth = 0.6
        XCTAssertEqual(options.resolvingBodyWidth(wide).minimumWidth,0.6)
        var predictor = PathPredictor()
        var update = PathUpdate()
        for i in 0...4 {
            update=predictor.update(result:fixture.frame(UInt64(i+1),1+Double(i)*0.1,cells:fixture.box),observation:nil,options:options)
        }
        XCTAssertEqual(try XCTUnwrap(update.path).requiredWidth,0.5)
        XCTAssertEqual(update.continuity?.requiredWidth,0.5)
        XCTAssertFalse(zip(update.path!.points,update.path!.points.dropFirst()).contains {a,b in
            (update.confirmedObstacles ?? []).contains{$0.overlaps(from:a,to:b,radius:0.25)}
        })
    }
    func testComfortFallsBackInNarrowPassage() throws {
        var r=fixture.frame(cells:{abs($0.x)>0.36 ? .obstacle:.candidate})
        r.planningObstacles = [-1,1].flatMap { sign in (0..<40).map { i in
            OccupancyFootprint(center:V3(Float(sign)*0.45,0,-Float(i)*0.1),right:V3(1,0,0),forward:V3(0,0,1),size:0.1)
        }}
        let raster=try XCTUnwrap(RoutePlanningGrid(result:r,options:PathOptions().resolvingBodyWidth(r.parameters),obstacleVeto:true))
        let reference=ForwardRouteReference(origin:.zero,forward:V3(0,0,-1),plane:r.plane!)
        let obstacle=ForwardObstacle(width:0.2,distance:3,extentObserved:true,near:3,far:3.2,minLateral:-0.1,maxLateral:0.1)
        let plan=try XCTUnwrap(ObstacleWaypointSearch.approach(raster:raster,reference:reference,obstacle:obstacle,foot:.zero,standOff:0.3,sideMargin:0.2))
        XCTAssertTrue(raster.supports(plan.points))
        var comfort=raster;comfort.requiredWidth=1.0
        XCTAssertFalse(comfort.supports(plan.points))
    }
}
