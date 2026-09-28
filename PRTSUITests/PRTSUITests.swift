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
        XCTAssertTrue(app.textFields["backendCommandField"].exists)
        XCTAssertLessThan(settings.frame.midY,camera.frame.midY)
        let home = XCTAttachment(screenshot:app.screenshot()); home.name = "Restored dark-teal home"; home.lifetime = .keepAlways; add(home)
        settings.tap()
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
    }

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
