//
//  PRTSUITests.swift
//  PRTSUITests
//
//  Created by yuanyuan on 2026/7/24.
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
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["settingsButton"]
        let camera = app.buttons["cameraButton"]
        XCTAssertTrue(settings.waitForExistence(timeout:10))
        XCTAssertTrue(camera.exists)
        #if PRTS_DEV_CAPTURE
        // Developer visibility is persisted and tested separately.
        #else
        XCTAssertFalse(app.textFields["backendCommandField"].exists)
        XCTAssertFalse(app.otherElements["homeDemoMetrics"].exists)
        #endif
        XCTAssertLessThan(settings.frame.midY,camera.frame.midY)
        let home = XCTAttachment(screenshot:app.screenshot()); home.name = "Restored dark-teal home"; home.lifetime = .keepAlways; add(home)
        settings.tap()
        XCTAssertEqual(app.navigationBars.buttons.count,1,"Settings must have only the system Back button")
        #if PRTS_DEV_CAPTURE
        let technical = app.switches["devTechnicalOverlayToggle"]
        if technical.value as? String != "1" { technical.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap() }
        let demo = app.buttons["demoOptionsLink"]
        if !demo.isHittable { app.swipeUp() }
        XCTAssertTrue(demo.waitForExistence(timeout:5))
        demo.tap()
        let cameraToggle = app.switches["demoCameraToggle"]
        XCTAssertTrue(cameraToggle.waitForExistence(timeout:5))
        let original = cameraToggle.value as? String
        cameraToggle.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value != %@",original ?? "1"),object:cameraToggle)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:3),.completed)
        cameraToggle.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()
        app.swipeUp()
        let metrics = app.switches["demoMetricsToggle"]
        XCTAssertTrue(metrics.waitForExistence(timeout:5))
        if metrics.value as? String != "1" { metrics.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap() }
        app.navigationBars.buttons.element(boundBy:0).tap()
        let spatial = app.buttons["spatialSettingsButton"]
        if !spatial.isHittable { app.swipeUp() }
        XCTAssertTrue(spatial.waitForExistence(timeout:5))
        spatial.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout:5))
        let settingsImage = XCTAttachment(screenshot:app.screenshot()); settingsImage.name = "Shared spatial settings"; settingsImage.lifetime = .keepAlways; add(settingsImage)
        app.buttons["完成"].tap()
        XCTAssertTrue(spatial.waitForExistence(timeout:5))
        app.buttons["返回"].firstMatch.tap()
        let metricTitle = app.staticTexts["空间感知 · 参数指标"]
        XCTAssertTrue(metricTitle.waitForExistence(timeout:5))
        XCTAssertGreaterThan(metricTitle.frame.width,10)
        let overlayImage = XCTAttachment(screenshot:app.screenshot()); overlayImage.name = "Home metrics overlay"; overlayImage.lifetime = .keepAlways; add(overlayImage)
        #else
        XCTAssertFalse(app.buttons["demoOptionsLink"].exists)
        XCTAssertFalse(app.buttons["spatialSettingsButton"].exists)
        XCTAssertFalse(app.switches["devTechnicalOverlayToggle"].exists)
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.buttons["cameraButton"].exists)
        #endif
    }

    /// Liquid Glass screens and the accessibility plan: localized settings, photo settings,
    /// and the stacked header at the largest accessibility text size.
    @MainActor
    func testLocalizedSettingsAndLargeTextHome() throws {
        func snap(_ app: XCUIApplication, _ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        let app = XCUIApplication()
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
        let photo = app.buttons["服务与 API Key"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        XCTAssertTrue(app.navigationBars["拍照描述"].waitForExistence(timeout: 5))
        snap(app, "Photo settings (zh)")
        // Provider picker: presets show their model; custom asks for address and model.
        // LabeledContent exposes the model as the row's value, not as its own label.
        func shown(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        }
        app.buttons["DeepSeek"].tap()
        XCTAssertTrue(shown("deepseek-flash").waitForExistence(timeout: 3))
        app.buttons["自定义"].tap()
        XCTAssertTrue(app.textFields["photoCustomEndpoint"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["photoCustomModel"].exists)
        snap(app, "Photo provider custom (zh)")
        app.buttons["通义千问 Qwen"].tap()
        XCTAssertTrue(shown("qwen3.8-flash").waitForExistence(timeout: 3))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The feedback section sits below the developer section; Form rows off screen don't exist yet.
        let haptic = app.switches["振动提示"]
        for _ in 0..<3 where !haptic.exists { app.swipeUp() }
        XCTAssertTrue(haptic.exists)
        snap(app, "Settings feedback (zh)")
        app.terminate()

        let large = XCUIApplication()
        large.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        large.launch()
        let largeSettings = large.buttons["settingsButton"]
        let camera = large.buttons["cameraButton"]
        XCTAssertTrue(largeSettings.waitForExistence(timeout: 10))
        XCTAssertTrue(largeSettings.isHittable)
        XCTAssertTrue(camera.isHittable)
        XCTAssertFalse(largeSettings.frame.intersects(camera.frame))
        // Header stays one row: the settings button becomes icon-only beside the brand.
        XCTAssertLessThan(largeSettings.frame.maxY, large.descendants(matching: .any)["cameraStatus"].frame.minY)
        snap(large, "Home at accessibility XXXL")
        camera.tap()
        let running = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '停止'"), object: camera)
        XCTAssertEqual(XCTWaiter.wait(for: [running], timeout: 8), .completed)
        snap(large, "Running at accessibility XXXL")
    }

    /// No-preview mode: guidance runs, nothing is drawn.
    @MainActor
    func testNoPreviewModeSkipsRendering() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-display.noPreview", "YES"]
        app.launch()
        let camera = app.buttons["cameraButton"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.tap()
        XCTAssertTrue(app.descendants(matching: .any)["noPreviewNotice"].waitForExistence(timeout: 8))
        sleep(3)
        #if PRTS_DEV_CAPTURE
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '绘制 0.0'")).firstMatch.exists)
        #endif
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "No preview running"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testCPUWithPreview() throws { try measureRunningCPU(noPreview: false) }
    @MainActor func testCPUWithoutPreview() throws { try measureRunningCPU(noPreview: true) }

    @MainActor
    private func measureRunningCPU(noPreview: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-display.noPreview", noPreview ? "YES" : "NO"]
        app.launch()
        let camera = app.buttons["cameraButton"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.tap()
        sleep(5)
        let options = XCTMeasureOptions(); options.iterationCount = 1
        measure(metrics: [XCTCPUMetric(application: app)], options: options) { sleep(20) }
    }

    @MainActor
    func testDevCaptureBuildGate() throws {
        let app = XCUIApplication(); app.launch()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout:10)); settings.tap()
        #if PRTS_DEV_CAPTURE
        app.swipeUp()
        let toggle = app.switches["devCaptureToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout:5))
        XCTAssertEqual(toggle.value as? String,"0")
        toggle.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()
        XCTAssertEqual(toggle.value as? String,"1")
        // Relaunch must never silently restart RGB recording.
        app.terminate(); app.launch(); app.buttons["settingsButton"].tap(); app.swipeUp()
        XCTAssertTrue(app.switches["devCaptureToggle"].waitForExistence(timeout:5))
        XCTAssertEqual(app.switches["devCaptureToggle"].value as? String,"0")
        #else
        XCTAssertFalse(app.switches["devCaptureToggle"].exists)
        #endif
    }

    #if PRTS_DEV_CAPTURE
    @MainActor
    func testDeveloperHomeVisibilitySwitches() throws {
        let app = XCUIApplication(); app.launch(); app.buttons["settingsButton"].tap()
        func set(_ id: String,_ enabled: Bool) {
            let toggle = app.switches[id]; XCTAssertTrue(toggle.waitForExistence(timeout:5))
            if toggle.value as? String != (enabled ? "1" : "0") { toggle.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap() }
        }
        set("devTechnicalOverlayToggle",false); set("devCommandEntryToggle",false)
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertFalse(app.staticTexts["空间感知 · 参数指标"].exists)
        XCTAssertFalse(app.textFields["backendCommandField"].exists)
        app.terminate(); app.launch()
        XCTAssertFalse(app.textFields["backendCommandField"].exists)
        app.buttons["settingsButton"].tap()
        set("devTechnicalOverlayToggle",true); set("devCommandEntryToggle",true)
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.textFields["backendCommandField"].waitForExistence(timeout:5))
    }
    #endif

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
