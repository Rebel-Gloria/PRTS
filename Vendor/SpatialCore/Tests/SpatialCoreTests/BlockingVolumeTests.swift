import XCTest
@testable import SpatialCore

final class BlockingVolumeTests: XCTestCase {
    private func grid() -> LocalGrid {
        let plane = GroundPlane(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
        let pose = RigidPose(position:V3(0,1.3,0))
        return .init(basis:GroundBasis(plane:plane,pose:pose)!,parameters:.init())
    }
    private func occupy(_ g: inout LocalGrid,_ indices: [Int],low: Float = 0.05,top: Float = 0.25,points: Int = 3) {
        for i in indices {
            g.cells[i].state = .obstacle; g.cells[i].obstacleSamples = points
            g.cells[i].minObstacleHeight = low; g.cells[i].maxObstacleHeight = top
        }
    }
    private func build(_ g: LocalGrid,_ p: ProbeParameters = .init()) -> BlockingVolumeModel {
        BlockingVolumeBuilder.build(grid:g,groundConfirmed:true,parameters:p)!
    }
    func testSupportedObjectBlocksItsWholeColumnUpToBodyHeight() {
        var g = grid(); let cells = [310,311]
        occupy(&g,cells)
        let m = build(g)
        XCTAssertEqual(m.columns.map(\.cellIndex),cells)
        XCTAssertEqual(m.summary.supportedGroups,1)
        XCTAssertEqual(m.summary.supportedEnvelopeVolume,0.005,accuracy:0.00001)
        for c in m.columns {
            XCTAssertEqual(c.measuredTop,0.25); XCTAssertEqual(c.ceiling,1.8)
            XCTAssertGreaterThan(c.ceiling,c.measuredTop) // Upper red space is a derived exclusion, not measured occupancy.
        }
    }
    func testUnknownGapIsNeverFilledByComponentBoundingBox() {
        var g = grid(); occupy(&g,[310,311,313,314])
        let m = build(g)
        XCTAssertEqual(m.summary.supportedGroups,2)
        XCTAssertFalse(m.columns.contains { $0.cellIndex == 312 })
        XCTAssertEqual(g.cells[312].state,.unknown)
    }
    func testTooSmallOrIsolatedSupportDoesNotCreateColumn() {
        var g = grid(); occupy(&g,[310],points:20)
        XCTAssertTrue(build(g).columns.isEmpty)
        occupy(&g,[312]) // Isolated from the first cell.
        XCTAssertTrue(build(g).columns.isEmpty)
        occupy(&g,[311],points:1)
        XCTAssertTrue(build(g).columns.isEmpty)
    }
    func testGroundAndLowRiseDoNotCreateVolumeColumn() {
        var g = grid(); occupy(&g,[310,311],low:0.031,top:0.04)
        XCTAssertTrue(build(g).columns.isEmpty)
        XCTAssertEqual(g.cells[310].state,.obstacle) // Never clears existing safety evidence.
    }
    func testLShapedFootprintDoesNotFillItsMissingCorner() {
        var g = grid(); occupy(&g,[310,311,340])
        let m = build(g)
        XCTAssertEqual(m.summary.columnCount,3)
        XCTAssertFalse(m.columns.contains { $0.cellIndex == 341 })
    }
    func testHeightSettingChangesCeilingNotMeasuredObject() {
        var g = grid(); occupy(&g,[310,311],low:0.8,top:1)
        var p = ProbeParameters(); p.bodyHeight = 2.1
        let m = build(g,p)
        XCTAssertEqual(m.columns.first?.measuredBottom,0.8)
        XCTAssertEqual(m.columns.first?.measuredTop,1)
        XCTAssertEqual(m.columns.first?.ceiling,2.1)
        XCTAssertEqual(m.summary.nominalCeiling,2.1)
    }
    func testUnconfirmedGroundOrRemovedObjectLeavesNoColumn() {
        var g = grid(); occupy(&g,[310,311])
        XCTAssertNil(BlockingVolumeBuilder.build(grid:g,groundConfirmed:false,parameters:.init()))
        XCTAssertEqual(build(g).columns.count,2)
        g.cells[310] = GridCell(); g.cells[311] = GridCell()
        XCTAssertTrue(build(g).columns.isEmpty) // No persistent column after current evidence is gone.
    }
    func testMissingOrInvalidHeightDoesNotCreateVolume() {
        var g = grid(); occupy(&g,[310,311]); g.cells[311].maxObstacleHeight = .nan
        XCTAssertTrue(build(g).columns.isEmpty)
        g.cells[311].maxObstacleHeight = nil
        XCTAssertTrue(build(g).columns.isEmpty)
    }
}
