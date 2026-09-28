import XCTest
import simd
@testable import SpatialCore

final class SpatialCoreTests: XCTestCase {
    let k = CameraIntrinsics(fx:200,fy:200,cx:159.5,cy:119.5,width:320,height:240)
    func testJournalReopenAfterStopDoesNotTruncateEarlierRecords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".jsonl")
        defer { try? FileManager.default.removeItem(at:url) }
        let first = try AppendFile.open(at:url)
        try first.write(contentsOf:Data("first\n".utf8)); try first.close()
        let reopened = try AppendFile.open(at:url)
        try reopened.write(contentsOf:Data("second\n".utf8)); try reopened.close()
        XCTAssertEqual(try String(contentsOf:url,encoding:.utf8),"first\nsecond\n")
    }
    func testProjectionRoundTripAndARAxisSigns() {
        let p = k.unproject(u:210,v:160,depth:2)
        XCTAssertGreaterThan(p.x,0); XCTAssertLessThan(p.y,0); XCTAssertEqual(p.z,-2)
        let uv = k.project(p)!
        XCTAssertEqual(uv.x,210,accuracy:0.0001); XCTAssertEqual(uv.y,160,accuracy:0.0001)
        XCTAssertNil(k.project(V3(0,0,1)))
    }
    func testPixelCenterIntrinsicsScaling() {
        let small = k.scaled(width:160,height:120)
        XCTAssertEqual(small.fx,100); XCTAssertEqual(small.cx,79.5)
        let a = k.unproject(u:100.5,v:60.5,depth:2),b = small.unproject(u:50,v:30,depth:2)
        XCTAssertLessThan(simd_distance(a,b),0.00001)
    }
    func testPoseRoundTrip() {
        let pose = RigidPose(right:V3(0,0,-1),up:V3(0,1,0),back:V3(1,0,0),position:V3(1,2,3))
        let p = V3(0.3,0.4,-2)
        XCTAssertLessThan(simd_distance(p,pose.camera(pose.world(p))),0.00001)
    }
    func testEveryOrientationIsInvertibleAndPreservesAllCorners() {
        for o in ImageOrientation.allCases {
            for p in [SIMD2<Float>(0,0),SIMD2(1,0),SIMD2(0,1),SIMD2(1,1),SIMD2(0.2,0.7)] {
                XCTAssertLessThan(simd_distance(p,o.imageUV(o.orientedUV(p))),0.00001)
                let q = o.orientedUV(p)
                XCTAssertTrue(q.x >= 0 && q.x <= 1 && q.y >= 0 && q.y <= 1)
            }
        }
    }
    func testAspectFitDoesNotCrop() {
        let rect = FitRect(imageWidth:1440,imageHeight:1920,viewportWidth:390,viewportHeight:844)
        XCTAssertEqual(rect.width,390,accuracy:0.001); XCTAssertEqual(rect.height,520,accuracy:0.001)
        XCTAssertGreaterThan(rect.y,0); XCTAssertEqual(rect.x,0)
    }
    func observation(conf: UInt8? = 2,z: Float = 3) -> DepthObservation {
        .init(width:320,height:240,depth:Array(repeating:z,count:320*240),confidence:conf.map { Array(repeating:$0,count:320*240) },intrinsics:k,pose:RigidPose(),timestamp:1,frameID:1,epoch:1)
    }
    func testMissingAndLowConfidenceAreNeverEvidence() {
        for conf in [nil,UInt8(0),UInt8(1)] {
            let o = observation(conf:conf)
            XCTAssertEqual(o.coverage(parameters:.init()),0); XCTAssertTrue(o.points(parameters:.init()).isEmpty)
        }
    }
    func testNaNAndOutOfRangeAreInvalid() {
        for z: Float in [.nan,.infinity,-1,0,100] { XCTAssertEqual(observation(z:z).coverage(parameters:.init()),0) }
    }
    func corners(front: Float = -1,back: Float = -1.1) -> [V3] {
        [-0.05,0.05].flatMap { x in [-0.05,0.05].flatMap { y in [front,back].map { z in V3(x,y,z) } } }
    }
    func testVisibilityBudgetExhaustionIsUnknownNotClear() {
        var o = observation()
        o.confidence![120*320+160] = 0
        var budget = 0
        XCTAssertFalse(VisibilityDepth(o,parameters:.init()).isClear(corners:corners(),margin:0.05,pixelBudget:&budget))
        XCTAssertEqual(budget,0)
        budget = 2
        XCTAssertFalse(VisibilityDepth(o,parameters:.init()).isClear(corners:corners(),margin:0.05,pixelBudget:&budget))
        XCTAssertGreaterThanOrEqual(budget,0)
    }
    func testUnconfirmedGroundSkipsClearanceButPreservesObstacles() {
        let o = observation(), p = GroundPlane(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
        let b = GroundBasis(plane:p,pose:RigidPose(position:V3(0,1.3,0)))!
        let points = floorPoints() + [V3(0.01,1,-2.01),V3(0.02,1,-2.02),V3(0.03,1,-2.03)]
        let g = GridBuilder.build(points:points,observation:o,plane:p,basis:b,parameters:.init(),evaluateClearance:false)
        XCTAssertFalse(g.cells.contains { $0.state == .candidate })
        XCTAssertTrue(g.cells.contains { $0.groundSamples > 0 && $0.reason == .groundUnconfirmed })
        XCTAssertEqual(g.cells[g.index(x:0.02,z:2.02)!].state,.obstacle)
    }
    func testVisibilityNeedsWholeRectangleAndRejectsOcclusion() {
        var o = observation()
        XCTAssertTrue(VisibilityDepth(o,parameters:.init()).isClear(corners:corners(),margin:0.05))
        o.confidence![120*320+160] = 0
        XCTAssertFalse(VisibilityDepth(o,parameters:.init()).isClear(corners:corners(),margin:0.05))
        XCTAssertFalse(VisibilityDepth(observation(z:0.7),parameters:.init()).isClear(corners:corners(),margin:0.05))
        XCTAssertFalse(VisibilityDepth(observation(),parameters:.init()).isClear(corners:corners(front:1,back:2),margin:0.05))
    }
    func floorPoints(y: Float = 0) -> [V3] {
        (0..<25).flatMap { z in (0..<25).map { x in V3(Float(x)*0.08-1,y,Float(z)*0.08-3) } }
    }
    func testSyntheticFloorWallProducesSupportedCandidateWithoutBridgingBlindZone() {
        // Explicitly synthetic ray-cast scene: floor y=0, opaque wall z=-5.
        let pose = RigidPose(position:V3(0,1.3,0))
        var depths = [Float]()
        for v in 0..<k.height { for u in 0..<k.width {
            let ray = k.unproject(u:Float(u),v:Float(v),depth:1)
            let floorDepth: Float = ray.y < 0 ? -1.3/ray.y : 100
            depths.append(min(5,floorDepth))
        }}
        let p = ProbeParameters()
        let o = DepthObservation(width:k.width,height:k.height,depth:depths,confidence:Array(repeating:2,count:depths.count),intrinsics:k,pose:pose,timestamp:1,frameID:1,epoch:1)
        let analyzer = SpatialAnalyzer()
        var result: AnalysisResult?
        for i in 0..<3 {
            var frame = o; frame.timestamp += Double(i)*0.1; frame.frameID += UInt64(i)
            result = analyzer.analyze(frame,priors:[FloorPrior(center:V3(0,0,-3),normal:V3(0,1,0))],parameters:p,parameterVersion:1,directionStable:true,source:"synthetic")
            if i < 2 {
                XCTAssertTrue(result!.segments.isEmpty)
                XCTAssertTrue(result!.distances.isEmpty)
                XCTAssertFalse(result!.grid!.cells.contains { $0.state == .candidate })
            }
        }
        XCTAssertEqual(result?.source,"synthetic")
        XCTAssertTrue(result?.plane?.floorPriorConfirmed == true)
        XCTAssertTrue(result?.grid?.cells.contains(where: { $0.state == .candidate }) == true)
        XCTAssertFalse(result!.segments.isEmpty)
        XCTAssertTrue(result!.segments.allSatisfy { $0.startDistance > 1 })
        XCTAssertTrue(result!.grid!.cells.prefix(10*result!.grid!.columns).allSatisfy { $0.state == .unknown })
    }
    func testGroundFitRequiresFloorPriorForConfirmation() {
        let pts = floorPoints()+[V3(0,0.9,-2),V3(0.5,1,-1)]
        let plain = GroundEstimator.fit(points:pts,priors:[],camera:V3(0,1.3,0),parameters:.init())!
        XCTAssertFalse(plain.floorPriorConfirmed)
        let plane = GroundEstimator.fit(points:pts,priors:[FloorPrior(center:V3(0,0,-2),normal:V3(0,1,0))],camera:V3(0,1.3,0),parameters:.init())!
        XCTAssertTrue(plane.floorPriorConfirmed); XCTAssertEqual(plane.offset,0,accuracy:0.0001)
        XCTAssertGreaterThan(plane.normal.y,0.99)
    }
    func testTableDoesNotBecomeFloorByImagePosition() {
        let plane = GroundEstimator.fit(points:floorPoints(y:0.7),priors:[FloorPrior(center:V3(0,0,-2),normal:V3(0,1,0))],camera:V3(0,1.5,0),parameters:.init())
        XCTAssertNotNil(plane); XCTAssertFalse(plane!.floorPriorConfirmed)
    }
    func testTiltedGroundReference() {
        let n = simd_normalize(V3(0,1,0.1)),plane = GroundPlane(normal:n,offset:0)
        let b = GroundBasis(plane:plane,pose:RigidPose(position:V3(1,1.3,0)))!
        XCTAssertEqual(plane.height(b.origin),0,accuracy:0.0001)
        XCTAssertEqual(simd_dot(b.forward,b.normal),0,accuracy:0.0001)
        let local = V3(0.5,0.4,2)
        XCTAssertLessThan(simd_distance(b.local(b.world(x:local.x,h:local.y,z:local.z)),local),0.0001)
    }
    func grid(_ state: CellState = .candidate) -> LocalGrid {
        let b = GroundBasis(plane:GroundPlane(normal:V3(0,1,0),offset:0),pose:RigidPose(position:V3(0,1.3,0)))!
        var grid = LocalGrid(basis:b,parameters:.init())
        grid.cells = Array(repeating:GridCell(state:state),count:grid.cells.count); return grid
    }
    func testUnknownIsDefaultAndNeverFilledFromPlane() {
        let g = grid(.unknown)
        XCTAssertEqual(g.unknownFraction,1); XCTAssertFalse(GridBuilder.footprintMask(grid:g,radius:0.45).contains(true))
    }
    func testFootprintRejectsUnknownAndInflatesObstacle() {
        var g = grid(); let middle = 15*g.columns+15
        g.cells[middle].state = .obstacle
        let mask = GridBuilder.footprintMask(grid:g,radius:0.45)
        XCTAssertFalse(mask[middle+4]); XCTAssertTrue(mask[middle+7])
        g.cells[middle].state = .unknown
        XCTAssertFalse(GridBuilder.footprintMask(grid:g,radius:0.45)[middle+4])
    }
    func testNarrowCorridorCannotFitBody() {
        var g = grid(.unknown)
        for z in 0..<g.rows { for x in 11...17 { g.cells[z*g.columns+x].state = .candidate } }
        XCTAssertFalse(GridBuilder.footprintMask(grid:g,radius:0.45).contains(true))
    }
    func testUnknownRowTruncatesWithoutRestartingBeyondGap() {
        var g = grid()
        for x in 0..<g.columns { g.cells[20*g.columns+x].state = .unknown }
        let mask = GridBuilder.footprintMask(grid:g,radius:0.1)
        let segments = ChannelPlanner.segments(grid:g,mask:mask)
        XCTAssertFalse(segments.isEmpty)
        for s in segments { XCTAssertTrue(s.cellIndices.allSatisfy { $0/g.columns < 20 }) }
    }
    func testNearBlindZoneIsNotConnectedToOrigin() {
        var g = grid()
        for i in 0..<(10*g.columns) { g.cells[i].state = .unknown }
        let segments = ChannelPlanner.segments(grid:g,mask:GridBuilder.footprintMask(grid:g,radius:0.1))
        XCTAssertFalse(segments.isEmpty); XCTAssertTrue(segments.allSatisfy { $0.startDistance > 1 })
    }
    func testSingleObstaclePixelDoesNotDefineDistance() {
        var g = grid(.unknown); let i = 10*g.columns+15
        g.cells[i].state = .obstacle; g.cells[i].obstacleSamples = 1
        XCTAssertTrue(ChannelPlanner.distances(grid:g).isEmpty)
        g.cells[i].obstacleSamples = 6
        XCTAssertEqual(ChannelPlanner.distances(grid:g).first!.groundDistance,simd_length(g.center(i)),accuracy:0.001)
    }
    func testGroundPixelsAloneCannotCertifyBodyClearance() {
        let o = observation(conf:nil),p = GroundPlane(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
        let b = GroundBasis(plane:p,pose:RigidPose(position:V3(0,1.3,0)))!
        let g = GridBuilder.build(points:floorPoints(),observation:o,plane:p,basis:b,parameters:.init())
        XCTAssertFalse(g.cells.contains { $0.state == .candidate })
    }
    func testHangingObstacleIsOccupiedDespiteFloorSupport() {
        let o = observation(),p = GroundPlane(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
        let b = GroundBasis(plane:p,pose:RigidPose(position:V3(0,1.3,0)))!
        let points = floorPoints() + [V3(0.01,1,-2.01),V3(0.02,1,-2.02),V3(0.03,1,-2.03)]
        let g = GridBuilder.build(points:points,observation:o,plane:p,basis:b,parameters:.init())
        let i = g.index(x:0.02,z:2.02)!
        XCTAssertEqual(g.cells[i].state,.obstacle)
    }
    func testResultAgeEpochAndOrderingGates() {
        var gate = ResultGate(); gate.reset(epoch:2)
        XCTAssertFalse(gate.accept(epoch:1,frameID:99,timestamp:10,now:10,maxAge:0.25))
        XCTAssertFalse(gate.accept(epoch:2,frameID:1,timestamp:9,now:10,maxAge:0.25))
        XCTAssertTrue(gate.accept(epoch:2,frameID:2,timestamp:10,now:10.1,maxAge:0.25))
        XCTAssertFalse(gate.accept(epoch:2,frameID:1,timestamp:10.1,now:10.1,maxAge:0.25))
    }
    func testDirectionChangeAndTrackingLossInvalidateImmediately() {
        var gate = DirectionGate(); let p = ProbeParameters(),pose = RigidPose()
        for i in 0...9 { _ = gate.update(pose:pose,time:Double(i)*0.1,trackingNormal:true,parameters:p) }
        XCTAssertTrue(gate.update(pose:pose,time:1,trackingNormal:true,parameters:p))
        let turned = RigidPose(right:V3(0,0,-1),up:V3(0,1,0),back:V3(1,0,0))
        XCTAssertFalse(gate.update(pose:turned,time:1.1,trackingNormal:true,parameters:p))
        XCTAssertFalse(gate.update(pose:pose,time:1.2,trackingNormal:false,parameters:p))
    }
    func testMailboxIsLatestOnlyAndRestartsAfterDraining() {
        let m = LatestMailbox<Int>()
        XCTAssertTrue(m.submit(1)); XCTAssertFalse(m.submit(2)); XCTAssertEqual(m.dropped,1)
        XCTAssertEqual(m.next(),2); XCTAssertNil(m.next()); XCTAssertTrue(m.submit(3)); XCTAssertEqual(m.next(),3)
    }
    func testSyntheticResultExplicitlyLabeledAndCodable() throws {
        let analyzer = SpatialAnalyzer()
        let result = analyzer.analyze(observation(conf:nil),priors:[],parameters:.init(),parameterVersion:1,directionStable:true,source:"synthetic")
        XCTAssertEqual(result.source,"synthetic"); XCTAssertTrue(result.segments.isEmpty)
        _ = try JSONDecoder().decode(AnalysisResult.self,from:JSONEncoder().encode(result))
    }
}
