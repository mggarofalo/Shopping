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

    func testSaveAndAddToListWorksForNewAndExistingCatalogItemsWithoutDuplicates() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingCatalogSaveAddUITest-\(UUID().uuidString).sqlite").path
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Catalog"].tap()

        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].waitForExistence(timeout: 2))
        app.textFields["shopping.catalog.name"].typeText("Oat milk")
        let saveAndAdd = app.buttons["shopping.catalog.saveAndAddToList"]
        XCTAssertTrue(saveAndAdd.isEnabled)
        saveAndAdd.tap()

        XCTAssertTrue(app.staticTexts["Added 1."].waitForExistence(timeout: 3))
        let view = app.buttons["shopping.catalog.viewNeed"]
        XCTAssertTrue(view.exists)
        view.tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["shopping.grocery.name"].value as? String, "Oat milk")
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.grocery.row."
        )).count, 1)
        app.tabBars.buttons["Catalog"].tap()
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.catalog.item.", "Oat milk"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        app.buttons["shopping.catalog.saveAndAddToList"].tap()

        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 3))
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.grocery.row."
        )).count, 1)
    }
}
