import XCTest
@testable import SpatialCore

final class ObstacleFeedbackFreshnessTests: XCTestCase {
    let fixture=ForwardRouteTests()
    func gate(_ time:Double,_ id:UInt64=10)->ResultPresentationGate {
        var g=ResultPresentationGate();g.enabled=true;g.trackingNormal=true
        g.epoch=1;g.parameterVersion=1;g.frameID=id;g.frameTimestamp=time
        return g
    }
    func testCameraTicksCannotRenewFailedObstacleChecks() throws {
        var predictor=PathPredictor()
        var good=fixture.frame();good.diagnostics?.sampledPoints=10
        let first=predictor.update(result:good,observation:nil,options:.init())
        XCTAssertEqual(try XCTUnwrap(first.successfulObstacleCheck).timestamp,1)
        var g=gate(1.25);g.parameterVersion=good.parameterVersion
        XCTAssertTrue(ObstacleFeedbackFreshness.allows(first,gate:g,hazardWatermark:0,now:1.25))
        var missing=fixture.frame(2,1.3);missing.plane=nil;missing.grid=nil
        let next=predictor.update(result:missing,observation:nil,options:.init())
        g.frameTimestamp=1.3
        XCTAssertEqual(next.successfulObstacleCheck?.timestamp,1)
        XCTAssertEqual(ObstacleFeedbackFreshness.state(next,gate:g,hazardWatermark:0,now:1.3),.unknown)
        XCTAssertEqual(next.waypointGuidance?.scenario,.clear) // No fabricated obstacle.
        g.frameTimestamp=1.15
        XCTAssertFalse(ObstacleFeedbackFreshness.allows(first,gate:g,hazardWatermark:0,now:1.14))
    }
    func testInvalidEvidenceNeverStartsClockAndRecoveryUsesSourceTime() throws {
        var predictor=PathPredictor()
        var r=fixture.frame();r.diagnostics?.sampledPoints=0
        XCTAssertNil(predictor.update(result:r,observation:nil,options:.init()).successfulObstacleCheck)
        r=fixture.frame(2,1.1);r.diagnostics?.sampledPoints=20;r.grid?.frameID=1
        XCTAssertNil(predictor.update(result:r,observation:nil,options:.init()).successfulObstacleCheck)
        r=fixture.frame(3,1.4);r.diagnostics?.sampledPoints=20
        let u=predictor.update(result:r,observation:nil,options:.init())
        var g=gate(1.45);g.parameterVersion=r.parameterVersion
        XCTAssertTrue(ObstacleFeedbackFreshness.allows(u,gate:g,hazardWatermark:0,now:1.45))
        g.minimumGuidanceFrameID=4
        XCTAssertFalse(ObstacleFeedbackFreshness.allows(u,gate:g,hazardWatermark:0,now:1.45))
        g.minimumGuidanceFrameID=0;g.epoch=2
        XCTAssertFalse(ObstacleFeedbackFreshness.allows(u,gate:g,hazardWatermark:0,now:1.45))
        r=fixture.frame(4,1.5);r.epoch=2;r.grid=nil;r.plane=nil
        XCTAssertNil(predictor.update(result:r,observation:nil,options:.init()).successfulObstacleCheck)
    }
    func testWatermarkAndClockReversalWithdrawAuthority() throws {
        var predictor=PathPredictor();var r=fixture.frame();r.diagnostics?.sampledPoints=10
        let u=predictor.update(result:r,observation:nil,options:.init())
        var g=gate(1.1);g.parameterVersion=r.parameterVersion
        XCTAssertFalse(ObstacleFeedbackFreshness.allows(u,gate:g,hazardWatermark:2,now:1.1))
        r=fixture.frame(2,0.9);r.diagnostics?.sampledPoints=10
        XCTAssertNil(predictor.update(result:r,observation:nil,options:.init()).successfulObstacleCheck)
    }
}
