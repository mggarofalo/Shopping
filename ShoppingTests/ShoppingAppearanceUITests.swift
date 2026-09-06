import XCTest

final class ShoppingAppearanceUITests: XCTestCase {
    func testAppearanceChoicePersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] =
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "Appearance-\(UUID().uuidString).sqlite"
            ).path
        defer { select("System", in: app) }
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        openSettings(app)
        let scheme = app.segmentedControls["shopping.appearance"]
        XCTAssertTrue(scheme.waitForExistence(timeout: 3))
        scheme.buttons["Light"].tap()
        attach("Light appearance", app)
        scheme.buttons["Dark"].tap()
        XCTAssertTrue(scheme.buttons["Dark"].isSelected)
        attach("Dark appearance", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        openSettings(app)
        XCTAssertTrue(app.segmentedControls["shopping.appearance"].buttons["Dark"].isSelected)
    }

    private func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
    }

    private func select(_ appearance: String, in app: XCUIApplication) {
        if app.state == .notRunning { app.launch() }
        openSettings(app)
        app.segmentedControls["shopping.appearance"].buttons[appearance].tap()
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
