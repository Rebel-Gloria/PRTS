import XCTest

final class GuidanceRecoveryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAssistiveTouchTapStopsGuidanceWithoutRestarting() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openAssistiveTouch(settings)
        let toggle = settings.switches["EnableAssistiveTouchSpecifier"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), settings.debugDescription)
        let wasEnabled = toggle.value as? String == "1"
        defer {
            settings.activate()
            if toggle.exists && (toggle.value as? String == "1") != wasEnabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(toggle.value as? String, wasEnabled ? "1" : "0")
        }
        continueAfterFailure = true
        if !wasEnabled {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '1'"),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)

        let app = XCUIApplication.prts()
        app.launch()
        app.buttons["settingsButton"].tap()
        let tapToStop = app.switches["tapToStopToggle"]
        for _ in 0..<6 where !tapToStop.isHittable { app.swipeUp() }
        XCTAssertTrue(tapToStop.waitForExistence(timeout: 5), app.debugDescription)
        let originallyTapToStop = tapToStop.value as? String == "1"
        defer {
            app.activate()
            app.buttons["settingsButton"].tap()
            for _ in 0..<6 where !tapToStop.isHittable { app.swipeUp() }
            if (tapToStop.value as? String == "1") != originallyTapToStop {
                tapToStop.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(tapToStop.value as? String, originallyTapToStop ? "1" : "0")
        }
        if !originallyTapToStop {
            tapToStop.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(tapToStop.value as? String, "1")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let button = app.buttons["cameraButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertRunning(app)
        XCTAssertTrue(["Stop", "停止"].contains(button.label), app.debugDescription)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["homeTips"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["homeTips"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["cameraStatus"].exists)
    }

    @MainActor
    private func openAssistiveTouch(_ settings: XCUIApplication) {
        settings.launch()
        // Settings preserves its navigation stack between launches.
        for _ in 0..<8 {
            let back = settings.navigationBars.buttons.element(boundBy: 0)
            if !back.exists || ["Edit", "编辑"].contains(back.label) { break }
            back.tap()
        }
        // Use the system identifier: this device labels Accessibility as “无障碍”.
        let accessibility = settings.buttons["com.apple.settings.accessibility"]
        for _ in 0..<6 where !accessibility.isHittable { settings.swipeDown() }
        for _ in 0..<8 where !accessibility.isHittable { settings.swipeUp() }
        XCTAssertTrue(accessibility.waitForExistence(timeout: 5), settings.debugDescription)
        accessibility.tap()
        for labels in [
            ["Touch", "触控", "触摸"],
            ["AssistiveTouch", "辅助触控", "辅助触摸"],
        ] {
            let initialTree = settings.debugDescription
            let row = settings.descendants(matching: .any)
                .matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            for _ in 0..<8 where !row.isHittable { settings.swipeUp() }
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                initialTree + "\nAfter scrolling:\n" + settings.debugDescription
            )
            row.tap()
        }
    }

    #if PRTS_DEV_CAPTURE
    @MainActor
    func testReadingInterruptedByBackgroundResumesGuidance() throws {
        let app = launchForReading()
        app.buttons["cameraButton"].tap()
        assertRunning(app)
        startReading(app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        assertRunning(app)
        XCTAssertFalse(app.descendants(matching: .any)["ocrStatus"].exists)
    }

    @MainActor
    func testReadingInterruptedBySettingsResumesGuidance() throws {
        let app = launchForReading()
        app.buttons["cameraButton"].tap()
        assertRunning(app)
        startReading(app)
        app.buttons["settingsButton"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        assertRunning(app)
        XCTAssertFalse(app.descendants(matching: .any)["ocrStatus"].exists)
    }

    @MainActor
    func testReadingFromIdleDoesNotStartGuidanceAfterBackground() throws {
        let app = launchForReading()
        startReading(app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["homeTips"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["cameraStatus"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ocrStatus"].exists)
    }

    @MainActor
    private func launchForReading() -> XCUIApplication {
        let app = XCUIApplication.prts()
        app.launchArguments += ["-developer.showCommandEntry", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["cameraButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func startReading(_ app: XCUIApplication) {
        let field = app.textFields["backendCommandField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("ocr\n")
        XCTAssertTrue(app.descendants(matching: .any)["ocrStatus"].waitForExistence(timeout: 5))
    }
    #endif

    @MainActor
    private func assertRunning(_ app: XCUIApplication) {
        let running = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label IN %@",
                ["长按停止", "Press and hold to stop", "停止", "Stop"]
            ),
            object: app.buttons["cameraButton"]
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [running], timeout: 15),
            .completed,
            app.debugDescription
        )
    }
}
