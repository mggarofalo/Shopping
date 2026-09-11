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

    func testFilteredRenameKeepsNeedAgainConfirmationAttachedToEditor() {
        let app = launchApp(named: "ShoppingCatalogFilteredRenameUITest", fixture: "populated")
        app.tabBars.buttons["Catalog"].tap()
        searchFor("Strawberries", in: app)
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.catalog.item.", "Strawberries"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()

        let name = app.textFields["shopping.catalog.name"]
        replace(name, with: "Blueberries")
        app.buttons["shopping.catalog.saveAndAddToList"].tap()

        let confirmation = app.sheets["Need Blueberries again?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertFalse(row.exists, "The renamed item should no longer match the active search")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 3))
    }

    func testGroceryAddSearchesCatalogAndFocusesExistingNeedWithoutDuplicates() {
        let app = launchApp(named: "ShoppingGroceryCatalogChooserUITest")
        app.tabBars.buttons["Catalog"].tap()
        app.buttons["shopping.catalog.add"].tap()
        app.textFields["shopping.catalog.name"].typeText("Oat milk")
        app.buttons["shopping.catalog.save"].tap()
        app.tabBars.buttons["Groceries"].tap()

        openCatalogChooser(in: app)
        searchFor("Oat", in: app)
        let result = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.catalogResult.", "Oat milk"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 2))
        result.tap()
        XCTAssertTrue(groceryRow(named: "Oat milk", in: app).waitForExistence(timeout: 3))

        openCatalogChooser(in: app)
        searchFor("Oat", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 2))
        result.tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 3))
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.grocery.row."
        )).count, 1)
    }

    func testGroceryAddNewPrefillsCatalogEditorAndOneTimeRemainsExplicit() {
        let app = launchApp(named: "ShoppingGroceryPrefillUITest")
        openCatalogChooser(in: app)
        searchFor("Rice vinegar", in: app)
        app.buttons["shopping.grocery.catalogAddNew"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.catalog.name"].value as? String, "Rice vinegar")
        app.buttons["shopping.catalog.saveAndAddToList"].tap()
        XCTAssertTrue(groceryRow(named: "Rice vinegar", in: app).waitForExistence(timeout: 3))

        openCatalogChooser(in: app)
        searchFor("Birthday candles", in: app)
        app.buttons["shopping.grocery.addOneTime"].tap()
        XCTAssertTrue(app.navigationBars["Add item"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["shopping.grocery.name"].value as? String, "Birthday candles")
        XCTAssertEqual(app.switches["shopping.grocery.remembered"].value as? String, "0")
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(groceryRow(named: "Birthday candles", in: app).waitForExistence(timeout: 3))

        app.tabBars.buttons["Catalog"].tap()
        XCTAssertFalse(app.staticTexts["Birthday candles"].exists)
    }

    private func launchApp(named name: String, fixture: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).sqlite").path
        if let fixture { app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture }
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        return app
    }

    private func openCatalogChooser(in app: XCUIApplication) {
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add from Catalog"].waitForExistence(timeout: 2))
    }

    private func searchFor(_ text: String, in app: XCUIApplication) {
        let search = app.searchFields["Search catalog"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.tap()
        search.typeText(text)
    }

    private func groceryRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.row.", name
        )).firstMatch
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        if let value = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }
}
