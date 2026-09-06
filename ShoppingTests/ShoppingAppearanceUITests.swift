import XCTest

final class ShoppingAppearanceUITests: XCTestCase {
    func testAppearanceChoicePersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] =
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "Appearance-\(UUID().uuidString).sqlite"
            ).path
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let scheme = app.segmentedControls["shopping.appearance"]
        XCTAssertTrue(scheme.waitForExistence(timeout: 3))
        scheme.buttons["Dark"].tap()
        XCTAssertTrue(scheme.buttons["Dark"].isSelected)
        app.terminate()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.segmentedControls["shopping.appearance"].buttons["Dark"].isSelected)
    }
}
