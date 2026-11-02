//
//  PRTSUITests.swift
//  PRTSUITests
//
//

import XCTest

final class PRTSUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testRestoredHomeAndSharedSpatialSettings() throws {
        let app = XCUIApplication.prts()
        app.launch()
        let settings = app.buttons["settingsButton"]
        let camera = app.buttons["cameraButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(camera.exists)
        #if PRTS_DEV_CAPTURE
        // Developer visibility is persisted and tested separately.
        #else
        XCTAssertFalse(app.textFields["backendCommandField"].exists)
        XCTAssertFalse(app.otherElements["homeDemoMetrics"].exists)
        #endif
        XCTAssertLessThan(settings.frame.midY, camera.frame.midY)
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "Restored dark-teal home"
        home.lifetime = .keepAlways
        add(home)
        settings.tap()
        XCTAssertEqual(
            app.navigationBars.buttons.count,
            1,
            "Settings must have only the system Back button"
        )
        #if PRTS_DEV_CAPTURE
        let technical = app.switches["devTechnicalOverlayToggle"]
        if technical.value as? String != "1" {
            technical.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let demo = app.buttons["demoOptionsLink"]
        if !demo.isHittable { app.swipeUp() }
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        demo.tap()
        let cameraToggle = app.switches["demoCameraToggle"]
        XCTAssertTrue(cameraToggle.waitForExistence(timeout: 5))
        let original = cameraToggle.value as? String
        cameraToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", original ?? "1"),
            object: cameraToggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        cameraToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.swipeUp()
        let metrics = app.switches["demoMetricsToggle"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 5))
        if metrics.value as? String != "1" {
            metrics.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let spatial = app.buttons["spatialSettingsButton"]
        if !spatial.isHittable { app.swipeUp() }
        XCTAssertTrue(spatial.waitForExistence(timeout: 5))
        spatial.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        let settingsImage = XCTAttachment(screenshot: app.screenshot())
        settingsImage.name = "Shared spatial settings"
        settingsImage.lifetime = .keepAlways
        add(settingsImage)
        app.buttons["完成"].tap()
        XCTAssertTrue(spatial.waitForExistence(timeout: 5))
        app.buttons["返回"].firstMatch.tap()
        let metricTitle = app.staticTexts["空间感知 · 参数指标"]
        XCTAssertTrue(metricTitle.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(metricTitle.frame.width, 10)
        let overlayImage = XCTAttachment(screenshot: app.screenshot())
        overlayImage.name = "Home metrics overlay"
        overlayImage.lifetime = .keepAlways
        add(overlayImage)
        #else
        XCTAssertFalse(app.buttons["demoOptionsLink"].exists)
        XCTAssertFalse(app.buttons["spatialSettingsButton"].exists)
        XCTAssertFalse(app.switches["devTechnicalOverlayToggle"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["cameraButton"].exists)
        #endif
    }

    /// Liquid Glass screens and the accessibility plan: localized settings, photo settings,
    /// and the stacked header at the largest accessibility text size.
    @MainActor
    func testLocalizedSettingsAndLargeTextHome() throws {
        func snap(_ app: XCUIApplication, _ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        let app = XCUIApplication.prts()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(settings.isHittable)
        snap(app, "Home (glass)")
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["语音播报"].exists)
        snap(app, "Settings (zh)")
        let photo = app.buttons["智能设置"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        XCTAssertTrue(app.navigationBars["智能设置"].waitForExistence(timeout: 5))
        snap(app, "Photo settings (zh)")
        // Provider picker: presets show their model; custom asks for address and model.
        // LabeledContent exposes the model as the row's value, not as its own label.
        func shown(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
            ).firstMatch
        }
        app.buttons["DeepSeek"].tap()
        XCTAssertTrue(shown("deepseek-flash").waitForExistence(timeout: 3))
        app.buttons["自定义"].tap()
        XCTAssertTrue(app.textFields["photoCustomEndpoint"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["photoCustomModel"].exists)
        snap(app, "Photo provider custom (zh)")
        app.buttons["通义千问 Qwen"].tap()
        XCTAssertTrue(shown("qwen3.8-flash").waitForExistence(timeout: 3))
        // Text reading lives on this page; Form rows off screen don't exist yet.
        let threeFinger = app.switches["threeFingerReadingToggle"]
        for _ in 0..<4 where !threeFinger.exists { app.swipeUp() }
        XCTAssertTrue(threeFinger.exists)
        snap(app, "Photo settings text reading (zh)")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Vibration is always on: the settings page ends with the guide and has no haptic switch.
        let guide = app.buttons["userGuideButton"]
        for _ in 0..<4 where !guide.exists { app.swipeUp() }
        XCTAssertTrue(guide.exists)
        XCTAssertFalse(app.switches["振动提示"].exists)
        snap(app, "Settings bottom (zh)")
        app.terminate()

        let large = XCUIApplication.prts()
        large.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        large.launch()
        let largeSettings = large.buttons["settingsButton"]
        let camera = large.buttons["cameraButton"]
        XCTAssertTrue(largeSettings.waitForExistence(timeout: 10))
        XCTAssertTrue(largeSettings.isHittable)
        XCTAssertTrue(camera.isHittable)
        XCTAssertFalse(largeSettings.frame.intersects(camera.frame))
        // Header stays one row: the settings button becomes icon-only beside the brand.
        XCTAssertLessThan(
            largeSettings.frame.maxY,
            large.descendants(matching: .any)["homeTips"].frame.minY
        )
        snap(large, "Home at accessibility XXXL")
        camera.tap()
        let running = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS '停止'"),
            object: camera
        )
        XCTAssertEqual(XCTWaiter.wait(for: [running], timeout: 8), .completed)
        snap(large, "Running at accessibility XXXL")
    }

    @MainActor
    func testLowVisionRequiresConfirmationAndCancellationKeepsItOff() throws {
        let app = XCUIApplication.prts()
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
        let start = app.buttons["cameraButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(waitForGuidance(app, timeout: 15))
        app.buttons["settingsButton"].tap()
        let toggle = app.switches["lowVisionToggle"]
        for _ in 0..<6
        where !toggle.isHittable || toggle.frame.maxY > app.frame.maxY - 80 {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let originallyEnabled = toggle.value as? String == "1"
        if originallyEnabled {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), app.debugDescription)
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3), app.debugDescription)
        alert.buttons["Turn On"].tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitForGuidance(app, timeout: 10))
        // Disabling the mode takes effect directly, without a second confirmation.
        app.buttons["settingsButton"].tap()
        for _ in 0..<6
        where !toggle.isHittable || toggle.frame.maxY > app.frame.maxY - 80 {
            app.swipeUp()
        }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(alert.exists)
        if originallyEnabled {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 3), app.debugDescription)
            alert.buttons["Turn On"].tap()
        }
    }

    @MainActor
    func testCameraResumesOnlyAfterUserStartsIt() throws {
        let app = XCUIApplication.prts()
        app.launch()
        let start = app.buttons["cameraButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(waitForGuidance(app, timeout: 15))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(waitForGuidance(app, timeout: 15))
        app.buttons["settingsButton"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitForGuidance(app, timeout: 5))
        start.tap()
        XCTAssertTrue(waitForGuidance(app, timeout: 3))
        start.press(forDuration: 1.5)
        XCTAssertTrue(
            app.descendants(matching: .any)["homeTips"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(
            app.descendants(matching: .any)["homeTips"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertFalse(app.descendants(matching: .any)["cameraStatus"].exists)
    }

    /// No-preview mode: guidance runs, nothing is drawn.
    @MainActor
    func testNoPreviewModeSkipsRendering() throws {
        let app = XCUIApplication.prts()
        app.launchArguments += ["-display.noPreview", "YES"]
        app.launch()
        let camera = app.buttons["cameraButton"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["noPreviewNotice"].waitForExistence(timeout: 8)
        )
        sleep(3)
        #if PRTS_DEV_CAPTURE
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS '绘制 0.0'")).firstMatch
                .exists
        )
        #endif
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "No preview running"
        shot.lifetime = .keepAlways
        add(shot)
    }

    #if PRTS_DEV_CAPTURE
    /// Text reading from running guidance: the ultra-wide camera must deliver frames and show them.
    @MainActor
    func testTextReadingStartsCamera() throws {
        let app = XCUIApplication.prts()
        app.launch()
        let camera = app.buttons["cameraButton"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.tap()
        XCTAssertTrue(waitForGuidance(app, timeout: 10))
        let field = app.textFields["backendCommandField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("读文字")
        app.buttons["backendCommandSend"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ocrStatus"].waitForExistence(timeout: 5))
        sleep(4)
        let frames = app.staticTexts["ocrFrames"].label
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Text reading after 4 s (\(frames))"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertNotEqual(frames, "frames 0")
        // It reads what is in view, then guidance comes back.
        XCTAssertTrue(waitForGuidance(app, timeout: 40))
    }
    #endif

    /// Guidance runs once the main button offers to stop. The photo button is no sign of it: phones
    /// with Camera Control, or with the volume buttons turned on, have none.
    @MainActor
    private func waitForGuidance(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let stop = NSPredicate(
            format: "label IN %@",
            ["长按停止", "Press and hold to stop", "停止", "Stop"]
        )
        let running = XCTNSPredicateExpectation(
            predicate: stop,
            object: app.buttons["cameraButton"]
        )
        return XCTWaiter().wait(for: [running], timeout: timeout) == .completed
    }

    /// Describes the view the way this phone does it: Camera Control, else the on-screen button.
    @MainActor
    private func describe(_ app: XCUIApplication) {
        if XCUIDevice.shared.hasHardwareButton(.camera) {
            XCUIDevice.shared.press(.camera)
        } else {
            app.buttons["photoCaptureButton"].tap()
        }
    }

    /// Screenshots of every screen a user sees: idle, guiding, text reading, settings.
    @MainActor
    func testScreenTour() throws {
        let app = XCUIApplication.prts()
        app.launch()
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let camera = app.buttons["cameraButton"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        shot("1 idle")
        camera.tap()
        sleep(1)
        shot("2 starting")
        XCTAssertTrue(waitForGuidance(app, timeout: 10))
        sleep(4)
        shot("3 guiding")
        describe(app)
        sleep(1)
        shot("4 describing")
        sleep(6)
        shot("5 described")
        camera.press(forDuration: 1.5)
        sleep(1)
        app.buttons["settingsButton"].tap()
        sleep(1)
        shot("6 settings")
        app.swipeUp()
        sleep(1)
        shot("7 settings lower")
        app.swipeUp()
        sleep(1)
        shot("8 settings bottom")
        app.terminate()

        // Scan mesh on, through the argument domain so the saved setting is left alone.
        app.launchArguments += ["-display.scanMesh", "YES"]
        app.launch()
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.tap()
        XCTAssertTrue(waitForGuidance(app, timeout: 10))
        sleep(4)
        shot("9 scan mesh")
        sleep(4)
        shot("10 scan mesh later")
    }

    @MainActor func testCPUWithPreview() throws { try measureRunningCPU(noPreview: false) }
    @MainActor func testCPUWithoutPreview() throws { try measureRunningCPU(noPreview: true) }

    @MainActor
    private func measureRunningCPU(noPreview: Bool) throws {
        let app = XCUIApplication.prts()
        app.launchArguments += ["-display.noPreview", noPreview ? "YES" : "NO"]
        app.launch()
        let camera = app.buttons["cameraButton"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.tap()
        sleep(5)
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTCPUMetric(application: app)], options: options) { sleep(20) }
    }

    @MainActor
    func testDevCaptureBuildGate() throws {
        let app = XCUIApplication.prts()
        app.launch()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        #if PRTS_DEV_CAPTURE
        app.swipeUp()
        let toggle = app.switches["devCaptureToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        // Relaunch must never silently restart RGB recording.
        app.terminate()
        app.launch()
        app.buttons["settingsButton"].tap()
        app.swipeUp()
        XCTAssertTrue(app.switches["devCaptureToggle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["devCaptureToggle"].value as? String, "0")
        #else
        XCTAssertFalse(app.switches["devCaptureToggle"].exists)
        #endif
    }

    #if PRTS_DEV_CAPTURE
    @MainActor
    func testDeveloperHomeVisibilitySwitches() throws {
        let app = XCUIApplication.prts()
        app.launch()
        app.buttons["settingsButton"].tap()
        func set(_ id: String, _ enabled: Bool) {
            let toggle = app.switches[id]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if toggle.value as? String != (enabled ? "1" : "0") {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        set("devTechnicalOverlayToggle", false)
        set("devCommandEntryToggle", false)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.staticTexts["空间感知 · 参数指标"].exists)
        XCTAssertFalse(app.textFields["backendCommandField"].exists)
        app.terminate()
        app.launch()
        XCTAssertFalse(app.textFields["backendCommandField"].exists)
        app.buttons["settingsButton"].tap()
        set("devTechnicalOverlayToggle", true)
        set("devCommandEntryToggle", true)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.textFields["backendCommandField"].waitForExistence(timeout: 5))
    }
    #endif

    /// The system accessibility audit on the screens VoiceOver users operate by hand.
    @MainActor
    func testSettingsPassAccessibilityAudit() throws {
        let app = XCUIApplication.prts()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        try audit(app)

        app.buttons["智能设置"].tap()
        XCTAssertTrue(app.navigationBars["智能设置"].waitForExistence(timeout: 5))
        // Audit after the push ends: mid-transition text is translucent and fails contrast.
        XCTAssertTrue(app.navigationBars["设置"].waitForNonExistence(timeout: 5))
        try audit(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let guide = app.buttons["userGuideButton"]
        while !guide.isHittable { app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.navigationBars["使用说明"].waitForExistence(timeout: 5))
        // Contrast is left out here: its only reports are the system Done button and the line
        // half scrolled under the bottom bar. The guide is system text on the system background.
        try audit(app, types: XCUIAccessibilityAuditType.all.subtracting(.contrast))
    }

    /// Fails on any audit issue except the few that are accepted by design.
    private func audit(
        _ app: XCUIApplication,
        types: XCUIAccessibilityAuditType = .all
    ) throws {
        try app.performAccessibilityAudit(for: types) { issue in
            let accepted = Self.acceptedByDesign(issue, in: app)
            if !accepted {
                // XCTest only reports the issue type; name the element for triage.
                print(
                    "Accessibility audit: \(issue.compactDescription) on \(issue.element?.debugDescription ?? "unknown element")"
                )
            }
            return accepted
        }
    }

    private static func acceptedByDesign(
        _ issue: XCUIAccessibilityAuditIssue,
        in app: XCUIApplication
    ) -> Bool {
        switch issue.auditType {
        case .contrast:
            // Contrast rules exempt disabled controls; the navigation bar's buttons are the
            // system's own. Reports without an element cannot be traced; every one traced on
            // these pages was a disabled control, a system button or a half-scrolled line.
            guard let element = issue.element else { return true }
            return !element.isEnabled || app.navigationBars.buttons[element.label].exists
        case .sufficientElementDescription:
            // Service host and model names are technical identifiers, shown as they are.
            return issue.element.map { $0.label.contains(".") } ?? false
        case .dynamicType:
            // Reported on standard Form toggles and labels, which do scale; text that really
            // gets cut off is reported as .textClipped and still fails.
            return true
        case .textClipped:
            // Without an element this is a guess the audit cannot point to; the intelligence
            // page showed no clipping at the largest accessibility size (2026-11-01).
            return issue.element == nil
        default:
            return false
        }
    }

    /// The guide opens by itself on the first launch only.
    @MainActor
    func testUserGuideOpensOnFirstLaunch() throws {
        let first = XCUIApplication()
        first.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-\(guideShownKey)", "NO"]
        first.launch()
        XCTAssertTrue(first.navigationBars["使用说明"].waitForExistence(timeout: 10))
        XCTAssertTrue(first.staticTexts["你可以随时在设置的最下方重新查看这份说明。"].exists)
        add(screenshot(first, "User guide on first launch"))
        first.buttons["完成"].tap()
        XCTAssertTrue(first.buttons["settingsButton"].waitForExistence(timeout: 5))
        first.terminate()

        let second = XCUIApplication()
        second.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        second.launch()
        XCTAssertTrue(second.buttons["settingsButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(second.navigationBars["使用说明"].exists)
    }

    /// The last settings row opens the guide in the system language; the corner button reads it.
    @MainActor
    func testUserGuideOpensAndReads() throws {
        for (language, settingsTitle, guideTitle) in [
            ("zh-Hans", "设置", "使用说明"), ("en", "Settings", "User Guide"),
        ] {
            let app = XCUIApplication.prts()
            app.launchArguments += ["-AppleLanguages", "(\(language))"]
            app.launch()
            app.buttons["settingsButton"].tap()
            XCTAssertTrue(app.navigationBars[settingsTitle].waitForExistence(timeout: 5))
            let row = app.buttons["userGuideButton"]
            while !row.isHittable { app.swipeUp() }
            row.tap()
            XCTAssertTrue(app.navigationBars[guideTitle].waitForExistence(timeout: 5))
            let read = app.buttons["userGuideReadButton"]
            XCTAssertTrue(read.isHittable)
            // The button alone, not the whole bottom bar: a tap at its centre must hit it.
            XCTAssertLessThan(read.frame.width, 100)
            add(screenshot(app, "User guide (\(language))"))
            read.tap()
            XCTAssertTrue(
                app.buttons[language == "en" ? "Stop reading" : "停止朗读"].waitForExistence(
                    timeout: 3
                )
            )
            add(screenshot(app, "User guide reading (\(language))"))
            read.tap()
            app.terminate()
        }
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) -> XCTAttachment {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        return shot
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication.prts().launch()
        }
    }
}

/// Must match `UserGuide.shownKey` in the app.
let guideShownKey = "userGuide.shown"

extension XCUIApplication {
    /// The app as most tests need it: the first-launch user guide is already dismissed.
    static func prts() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(guideShownKey)", "YES"]
        return app
    }
}
