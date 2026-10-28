import XCTest
@testable import SpatialCore

final class HapticEntryTests: XCTestCase {
    func heading(_ degrees:Float)->PathHeading {
        .init(angleDegrees:degrees,crossTrack:0,startDistance:0,target:V3(0,0,-1),remainingLength:1)
    }
    func testNeutralWaitsForTwelveDegreesThenTurnContinuesToFive() {
        var p=PathHapticPolicy()
        for (i,a) in [Float(6),8,11.99].enumerated() {
            XCTAssertNil(p.update(heading:heading(a),now:Double(i)*0.1,enabled:true,threshold:12))
            XCTAssertEqual(p.mode,"neutral")
        }
        XCTAssertEqual(p.update(heading:heading(12),now:0.3,enabled:true,threshold:12)?.kind,"right_long")
        _=p.update(heading:heading(8),now:0.4,enabled:true,threshold:12)
        XCTAssertEqual(p.mode,"right_long")
        XCTAssertNil(p.update(heading:heading(5),now:0.5,enabled:true,threshold:12))
        XCTAssertTrue(p.stopCurrentPattern)
        _=p.update(heading:heading(5),now:0.6,enabled:true,threshold:12)
        _=p.update(heading:heading(5),now:0.7,enabled:true,threshold:12)
        XCTAssertEqual(p.update(heading:heading(5),now:0.8,enabled:true,threshold:12)?.kind,"aligned_once")
    }
    func testNeutralBandBreaksAlignmentDwellAndPauseCancelsDirection() {
        var p=PathHapticPolicy()
        _=p.update(heading:heading(4),now:0,enabled:true,threshold:12)
        _=p.update(heading:heading(4),now:0.1,enabled:true,threshold:12)
        XCTAssertNil(p.update(heading:heading(8),now:0.2,enabled:true,threshold:12))
        XCTAssertNil(p.update(heading:heading(4),now:0.3,enabled:true,threshold:12))
        XCTAssertNil(p.update(heading:heading(4),now:0.4,enabled:true,threshold:12))
        XCTAssertEqual(p.update(heading:heading(-12),now:0.5,enabled:true,threshold:12)?.kind,"left_double")
        XCTAssertNil(p.update(heading:nil,now:0.6,enabled:true,threshold:12))
        XCTAssertTrue(p.stopCurrentPattern)
        XCTAssertNil(p.update(heading:heading(8),now:0.7,enabled:true,threshold:12))
    }
}
