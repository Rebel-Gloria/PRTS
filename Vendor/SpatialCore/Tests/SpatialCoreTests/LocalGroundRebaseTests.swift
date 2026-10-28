import XCTest
import simd
@testable import SpatialCore

final class LocalGroundRebaseTests: XCTestCase {
    let fixture = ForwardRouteTests()
    func testOnlyConfirmedPlaneBeyondThresholdRebasesWithoutRestartingObstacleAge() throws {
        var filter = TemporalOccupancyGrid()
        for i in 0...4 {
            var r = fixture.frame(UInt64(i+1),1+Double(i)*0.1,cells:fixture.box)
            r.plane = GroundPlane(normal:V3(0,1,0),offset:i >= 2 ? -0.1 : 0)
            r.diagnostics?.groundConfirmed = i >= 3
            let model = try XCTUnwrap(filter.apply(r))
            XCTAssertEqual(model.plane!.offset, i >= 3 ? -0.1 : 0)
            if i == 3 {
                XCTAssertGreaterThan(filter.diagnostics.confirmedCells,0)
                XCTAssertEqual(filter.diagnostics.maximumAge,0.3,accuracy:0.00001)
            }
        }
        XCTAssertFalse(LocalGroundRebase.needed(from:.init(normal:V3(0,1,0),offset:0),to:.init(normal:V3(0,1,0),offset:0.039),at:.zero))
        let a:Float = 3.1 * .pi / 180
        XCTAssertTrue(LocalGroundRebase.needed(from:.init(normal:V3(0,1,0),offset:0),to:.init(normal:V3(sin(a),cos(a),0),offset:0),at:.zero))
    }
    func testRebasePreservesRouteGoalAndPreviewXZ() throws {
        var planner = ObstacleWaypointPlanner()
        var r = fixture.frame(cells:fixture.box);r.planningObstacles=[]
        let before = planner.update(result:r,cameraResult:nil,options:.init(),view:nil)
        let path = try XCTUnwrap(before.path)
        r = fixture.frame(2,1.1,cells:fixture.box);r.planningObstacles=[]
        r.plane = .init(normal:V3(0,1,0),offset:-0.2)
        let after = planner.update(result:r,cameraResult:nil,options:.init(),view:nil)
        XCTAssertEqual(after.goal?.id,before.goal?.id)
        XCTAssertEqual(after.goal?.point.x,before.goal?.point.x)
        XCTAssertEqual(after.goal?.point.z,before.goal?.point.z)
        XCTAssertEqual(after.path?.points.map{SIMD2($0.x,$0.z)},path.points.map{SIMD2($0.x,$0.z)})
        XCTAssertTrue(try XCTUnwrap(after.path).points.allSatisfy{abs($0.y-0.2)<0.00001})
        XCTAssertEqual(after.waypointGuidance?.nextTarget?.x,before.waypointGuidance?.nextTarget?.x)
        XCTAssertEqual(after.waypointGuidance?.nextTarget?.z,before.waypointGuidance?.nextTarget?.z)
    }
    func testRebaseCannotPublishAnIntersectingBodySweep() throws {
        var planner = ObstacleWaypointPlanner()
        var r = fixture.frame(cells:fixture.box);r.planningObstacles=[]
        XCTAssertNotNil(planner.update(result:r,cameraResult:nil,options:.init(),view:nil).path)
        r = fixture.frame(2,1.1,cells:fixture.box)
        r.plane = .init(normal:V3(0,1,0),offset:-0.2)
        r.planningObstacles=[.init(center:V3(0,0.2,0),right:V3(1,0,0),forward:V3(0,0,1),size:4)]
        let after = planner.update(result:r,cameraResult:nil,options:.init(),view:nil)
        XCTAssertNil(after.path)
        XCTAssertNil(after.goal)
        XCTAssertEqual(after.waypointGuidance?.scenario,.blocked)
    }
}
