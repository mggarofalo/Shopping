import XCTest

final class ShoppingLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsGroceryListShell() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingUITest-\(UUID().uuidString).sqlite").path
        app.launch()

        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        let emptyState = app.descendants(matching: .any)["shopping.emptyState"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your grocery list"].exists)
    }
}
