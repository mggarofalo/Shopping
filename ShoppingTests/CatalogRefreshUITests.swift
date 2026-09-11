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
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.catalog.item.", "Fresh basil"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertEqual(row.value as? String, "Recently added")
        XCTAssertTrue(row.isHittable, "The newly saved row should be scrolled into view")
        XCTAssertTrue(app.navigationBars["Catalog"].exists)

        app.tabBars.buttons["Groceries"].tap()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        XCTAssertEqual(row.value as? String, "")

        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].waitForExistence(timeout: 2))
        app.textFields["shopping.catalog.name"].typeText("Fresh basil")
        app.buttons["Edit Fresh basil"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        app.buttons["shopping.catalog.save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        XCTAssertEqual(row.value as? String, "")
    }
}
