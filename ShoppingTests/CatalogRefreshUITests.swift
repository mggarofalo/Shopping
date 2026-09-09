import XCTest

final class CatalogRefreshUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNewCatalogItemAppearsWithoutNavigatingAway() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingCatalogRefreshUITest-\(UUID().uuidString).sqlite").path
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Catalog"].tap()
        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].waitForExistence(timeout: 2))
        app.textFields["shopping.catalog.name"].typeText("Fresh basil")
        app.buttons["shopping.catalog.save"].tap()

        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.catalog.item.", "Fresh basil"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Catalog"].exists)
    }
}
