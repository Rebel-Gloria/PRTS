import XCTest

/// Run this setup before unattended hardware tests. It only grants the app's declared input
/// permissions; provider selection and photo-upload consent remain user settings.
final class PermissionSetupUITests: XCTestCase {
    @MainActor
    func testPrepareCameraAndSpeechPermissions() throws {
        continueAfterFailure = false
        let app = XCUIApplication.prts()
        app.launch()
        XCTAssertTrue(app.buttons["cameraButton"].waitForExistence(timeout: 10))
        app.buttons["cameraButton"].tap()
        let running = NSPredicate(
            format: "label IN %@",
            ["长按停止", "Press and hold to stop", "停止", "Stop"]
        )
        try allowPrompts(until: { running.evaluate(with: app.buttons["cameraButton"]) })
        app.buttons["cameraButton"].press(forDuration: 1.5)
        app.buttons["settingsButton"].tap()
        app.buttons["intelligenceSettingsLink"].tap()

        let granted = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label IN %@",
                [
                    "麦克风和语音识别已允许", "Microphone and speech recognition allowed",
                ]
            )
        ).firstMatch
        let request = app.buttons["photoSpeechPermissions"]
        for _ in 0..<10 where !request.isHittable && !granted.isHittable { app.swipeUp() }
        if !granted.exists {
            XCTAssertTrue(request.isHittable, app.debugDescription)
            request.tap()
            try allowPrompts(until: { granted.exists })
        }
        XCTAssertTrue(granted.exists, app.debugDescription)
        print("PRTS_PERMISSIONS_READY camera microphone speechRecognition automation")
    }

    @MainActor
    private func allowPrompts(until ready: () -> Bool) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if ready() { return }
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 1) {
                let allow = alert.buttons.matching(
                    NSPredicate(format: "label IN %@", ["允许", "好", "Allow", "OK"])
                ).firstMatch
                XCTAssertTrue(allow.exists, alert.debugDescription)
                allow.tap()
            }
        }
        XCTFail("Permission setup did not complete within 30 seconds")
    }
}
