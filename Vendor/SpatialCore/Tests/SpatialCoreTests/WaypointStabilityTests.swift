import XCTest
import simd
@testable import SpatialCore

/// Synthetic timestamps and geometry; not live-sensor validation.
final class WaypointStabilityTests: XCTestCase {
    private let fixture = ForwardRouteTests()
}

extension WaypointStabilityTests {
    func testNearFarAndClearJitterDoesNotChangeScenarioUntilSettled() {
        var latch = WaypointScenarioLatch()
        func obstacle(_ d: Float) -> ForwardObstacle {
            .init(width:0.5,distance:d,extentObserved:true,near:d,far:d+0.2,minLateral:-0.25,maxLateral:0.25)
        }
        XCTAssertEqual(latch.update(nil,now:0,nearDistance:2).0,.clear)
        XCTAssertEqual(latch.update(obstacle(1.8),now:0.1,nearDistance:2).0,.nearObstacle)
        XCTAssertEqual(latch.update(obstacle(3),now:0.2,nearDistance:2).0,.nearObstacle)
        XCTAssertEqual(latch.update(nil,now:0.3,nearDistance:2).0,.nearObstacle)
        XCTAssertEqual(latch.update(obstacle(1.9),now:0.4,nearDistance:2).0,.nearObstacle)
        XCTAssertEqual(latch.update(obstacle(3),now:0.5,nearDistance:2).0,.nearObstacle)
        XCTAssertEqual(latch.update(obstacle(3),now:1.0,nearDistance:2).0,.nearObstacle)
        XCTAssertEqual(latch.update(obstacle(3),now:1.25,nearDistance:2).0,.distantObstacle)
        XCTAssertEqual(latch.update(nil,now:1.3,nearDistance:2).0,.distantObstacle)
        XCTAssertEqual(latch.update(nil,now:1.9,nearDistance:2).0,.clear)
    }
    func testImageEdgeJitterDoesNotRedirectButLargeExitDoes() {
        var visibility = WaypointVisibilityLatch()
        let view = RouteCameraView(intrinsics:.init(fx:100,fy:100,cx:49.5,cy:49.5,width:100,height:100))
        XCTAssertFalse(visibility.exited(target:V3(1.01,0,-2),view:view,pose:.init(),now:0))
        XCTAssertFalse(visibility.exited(target:V3(1.15,0,-2),view:view,pose:.init(),now:0.1))
        XCTAssertFalse(visibility.exited(target:V3(1,0,-2),view:view,pose:.init(),now:0.2))
        XCTAssertFalse(visibility.exited(target:V3(1.15,0,-2),view:view,pose:.init(),now:0.3))
        XCTAssertTrue(visibility.exited(target:V3(1.15,0,-2),view:view,pose:.init(),now:0.65))
        XCTAssertTrue(visibility.exited(target:V3(3,0,-2),view:view,pose:.init(),now:0.7))
    }

}

extension WaypointStabilityTests {
    func testFartherComponentDoesNotReplaceActiveBypassGoal() throws {
        var planner = ObstacleWaypointPlanner()
        let near: (V3)->CellState = { abs($0.x)<0.1 && -$0.z>0.8 && -$0.z<1 ? .obstacle : .candidate }
        let first = planner.update(result:fixture.frame(cells:near),cameraResult:nil,options:.init(),view:nil)
        let goal = try XCTUnwrap(first.goal)
        for i in 1...20 {
            let r=fixture.frame(UInt64(i+1),1+Double(i)*0.1,cells: { abs($0.x)<0.1 && -$0.z>3 && -$0.z<3.2 ? .obstacle : .candidate })
            let next=planner.update(result:r,cameraResult:nil,options:.init(),view:nil)
            XCTAssertEqual(next.goal?.id,goal.id)
            XCTAssertEqual(next.goal?.point,goal.point)
        }
    }
    func testClearTransitionCannotDelayNewConfirmedPathCollision() throws {
        var planner = ObstacleWaypointPlanner()
        let first = planner.update(result:fixture.frame(cells:fixture.box),cameraResult:nil,options:.init(),view:nil)
        let target = try XCTUnwrap(first.goal?.point)
        _ = planner.update(result:fixture.frame(2,1.1,cells:{ _ in .candidate }),cameraResult:nil,options:.init(),view:nil)
        let r=fixture.frame(3,1.2,cells:{simd_distance($0,target)<0.12 ? .obstacle : .candidate})
        let next=planner.update(result:r,cameraResult:nil,options:.init(),view:nil)
        XCTAssertNotEqual(next.goal?.point,target)
        if let path=next.path { XCTAssertTrue(RoutePlanningGrid(result:r,obstacleVeto:true)!.supports(path.points)) }
    }
}

extension WaypointStabilityTests {
    func testVisibleSegmentInteriorCanBeGoalWithoutCuttingCorners() throws {
        let view=RouteCameraView(intrinsics:.init(fx:100,fy:100,cx:49.5,cy:49.5,width:100,height:100))
        let plan=ObstacleWaypointSearch.Plan(points:[V3(-2,0,-2),V3(2,0,-2),V3(3,0,-3)],side:1)
        XCTAssertNil(ObstacleWaypointSearch.targetIndex(in:plan.points,pose:.init(),view:view))
        let (visible,index)=try XCTUnwrap(ObstacleWaypointSearch.visiblePlan(plan,pose:.init(),view:view,normal:V3(0,1,0),minimumDistance:0.55))
        XCTAssertTrue(view.contains(visible.points[index],pose:.init()))
        XCTAssertEqual(visible.points[0],plan.points[0])
        XCTAssertEqual(visible.points[index].z,-2,accuracy:0.0001)
        XCTAssertEqual(Array(visible.points.dropFirst(index+1)),Array(plan.points.dropFirst()))
    }
}
