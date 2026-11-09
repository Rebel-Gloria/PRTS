import XCTest

final class RecordingModeUITests: XCTestCase {
    @MainActor
    func testRecordingModeBuildGateAndRelaunch() {
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication.prts()
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
            app.launch()
            let start = app.buttons["cameraButton"]
            XCTAssertTrue(start.waitForExistence(timeout: 10))
            let toggle = app.switches["recordingModeToggle"]
            #if PRTS_DEV_CAPTURE
            XCTAssertTrue(toggle.exists)
            XCTAssertTrue(toggle.isHittable)
            XCTAssertLessThanOrEqual(toggle.frame.maxY, start.frame.minY)
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1")
            app.terminate()
            app.launch()
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            XCTAssertEqual(toggle.value as? String, "0")
            #else
            XCTAssertFalse(toggle.exists)
            #endif
            app.terminate()
        }
    }
}
