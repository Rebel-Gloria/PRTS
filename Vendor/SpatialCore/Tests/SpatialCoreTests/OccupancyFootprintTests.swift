import XCTest
import simd
@testable import SpatialCore

/// Synthetic geometry/time. These tests do not treat a sampled recording as full-rate truth.
final class OccupancyFootprintTests: XCTestCase {
    private let fixture = ForwardRouteTests()
    func testConfirmedGeometryUsesLatestCellNotAssociationAnchor() throws {
        var filter = TemporalOccupancyGrid()
        for i in 0...3 {
            _ = filter.apply(fixture.frame(UInt64(i+1), 1+Double(i)*0.1, cells: {
                abs($0.x) < 0.051 && -$0.z > 0.9 && -$0.z < 1.01 ? .obstacle : .unknown
            }))
        }
        let r = fixture.frame(5,1.4,pose:.init(position:V3(0.09,1.4,0)),cells:{
            $0.x > 0.1 && $0.x < 0.2 && -$0.z > 0.9 && -$0.z < 1.01 ? .obstacle : .unknown
        })
        let model = try XCTUnwrap(filter.apply(r))
        let raster = try XCTUnwrap(RoutePlanningGrid(result:model,obstacleVeto:true))
        // The current occupied square spans x=[.09,.19]. The old matching anchor is x=.05.
        // A half-metre-wide route at x=.41 overlaps current occupancy, but not the old cell.
        XCTAssertFalse(raster.supports([V3(0.41,0,-0.7),V3(0.41,0,-1.3)]))
    }

    func testRotatedQueryCannotForgetAConfirmedWallOutsideItsRaster() throws {
        var filter = TemporalOccupancyGrid()
        var r = fixture.frame()
        for i in 0...3 {
            r = fixture.frame(UInt64(i+1),1+Double(i)*0.1,cells: { abs($0.x)<0.15 && -$0.z>1.9 && -$0.z<2.2 ? .obstacle : .unknown })
            _ = filter.apply(r)
        }
        let rotated = try XCTUnwrap(filter.projected(r,forwardLength:8,forward:V3(1,0,0)))
        let raster = try XCTUnwrap(RoutePlanningGrid(result:rotated,obstacleVeto:true))
        XCTAssertFalse(raster.supports([V3(0,0,0),V3(0,0,-3)]))
        XCTAssertTrue(raster.supports([V3(0.8,0,0),V3(0.8,0,-3)]))
    }
}

extension OccupancyFootprintTests {
    func testRotatedFootprintStampDoesNotLeaveCentreOnlyCracks() {
        var r = fixture.frame()
        let square = OccupancyFootprint(center:V3(0,0,-1),right:simd_normalize(V3(1,0,1)),forward:simd_normalize(V3(1,0,-1)),size:0.3)
        square.stamp(into:&r.grid!)
        for x:Float in [-0.12,0,0.12] {
            let a=V3(x,0,-0.9),b=V3(x,0,-1.1)
            XCTAssertTrue(square.overlaps(from:a,to:b,radius:0.01))
            XCTAssertFalse(RoutePlanningGrid(result:r,obstacleVeto:true)!.supports([a,b]))
        }
    }
}

extension OccupancyFootprintTests {
    func testEveryConfirmedSquareSurvivesSharedAssociationBinsAndDisappearanceClearsIt() throws {
        var filter = TemporalOccupancyGrid(), model: AnalysisResult?
        for i in 0...3 {
            model=filter.apply(fixture.frame(UInt64(i+1),1+Double(i)*0.1,pose:fixture.pose(yaw:30),cells:{
                abs($0.x)<0.8 && -$0.z>0.5 && -$0.z<2 ? .obstacle : .unknown
            }))
        }
        XCTAssertGreaterThan(filter.diagnostics.confirmedCells,20)
        XCTAssertEqual(try XCTUnwrap(model?.planningObstacles).count,filter.diagnostics.confirmedCells)
        let cleared=try XCTUnwrap(filter.apply(fixture.frame(5,1.4,cells:{ _ in .unknown })))
        XCTAssertEqual(cleared.planningObstacles?.count,0)
        XCTAssertTrue(RoutePlanningGrid(result:cleared,obstacleVeto:true)!.supports([V3(0,0,0),V3(0,0,-3)]))
    }
}
