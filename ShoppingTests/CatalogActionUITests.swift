import XCTest

final class CatalogActionUITests: XCTestCase {
    func testNewItemHandoffPrefillsEditorAndSavesOnlyAfterExplicitAction() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "empty"
        app.launchEnvironment["SHOPPING_UI_TEST_NEW_CATALOG_NAME"] = "Space pears"
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 10))
        let name = app.textFields["shopping.catalog.name"]
        XCTAssertEqual(name.value as? String, "Space pears")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Prefilled new item from system action"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars["New catalog item"].buttons["Cancel"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["New catalog item"]
        )], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Add to Groceries"].existsOrAppears(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.catalogResult.")).firstMatch.exists)
        app.buttons["shopping.grocery.catalogAddNew"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 5))
        app.buttons["shopping.catalog.saveAndAddToList"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        XCTAssertTrue(app.staticTexts["Space pears"].existsOrAppears(timeout: 5))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_NEW_CATALOG_NAME")
        app.launch()
        XCTAssertTrue(app.staticTexts["Space pears"].existsOrAppears(timeout: 8))
    }
}
