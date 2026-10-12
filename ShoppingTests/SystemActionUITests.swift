import XCTest

final class SystemActionUITests: XCTestCase {
    func testHomeScreenAddOpensCatalogAddWithoutChangingList() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        app.buttons["Recently cleared"].tap()
        XCTAssertTrue(app.navigationBars["Recently cleared"].existsOrAppears(timeout: 5))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Milk & Bananas"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        icon.press(forDuration: 1.2)
        let action = springboard.buttons["Add item"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let menu = XCTAttachment(screenshot: springboard.screenshot())
        menu.name = "Three Home Screen actions"
        menu.lifetime = .keepAlways
        add(menu)
        action.tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].existsOrAppears(timeout: 10))
        XCTAssertTrue(app.searchFields["Search catalog"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.existsOrAppears(timeout: 3))
        // Active native search hides the sheet toolbar until search is dismissed.
        let closeSearch = app.buttons["Close"]
        if closeSearch.existsOrAppears(timeout: 2) {
            closeSearch.tap()
        } else {
            app.buttons["Cancel"].tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["shopping.grocery.catalogCancel"].existsOrAppears(timeout: 3))
        app.buttons["shopping.grocery.catalogCancel"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
    }
}
