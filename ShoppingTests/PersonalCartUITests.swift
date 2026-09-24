import XCTest

final class PersonalCartUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPersonalCheckoutAndRecoverySurviveRelaunch() {
        let app = launch()
        let grocery = groceryRow("Granola", app: app)
        XCTAssertTrue(grocery.waitForExistence(timeout: 8))
        grocery.swipeLeft()
        let cartAction = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.checklist.cart.")).firstMatch
        XCTAssertTrue(cartAction.waitForExistence(timeout: 3))
        cartAction.tap()
        app.buttons["In cart (1)"].tap()
        XCTAssertTrue(app.navigationBars["My cart"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).firstMatch.exists)
        app.buttons["Check out"].tap()
        XCTAssertTrue(app.navigationBars["Check out"].waitForExistence(timeout: 3))
        app.buttons["Confirm"].tap()
        XCTAssertTrue(app.staticTexts["Your cart is empty in this view"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 8))
        XCTAssertFalse(groceryRow("Granola", app: app).exists)
        app.buttons["Recently cleared"].tap()
        XCTAssertTrue(app.navigationBars["My purchases"].waitForExistence(timeout: 3))
        app.buttons["Undo this purchase"].tap()
        XCTAssertTrue(app.staticTexts["Purchase undone"].waitForExistence(timeout: 3))
        app.navigationBars["My purchases"].buttons.firstMatch.tap()
        app.buttons["In cart (1)"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).firstMatch.waitForExistence(timeout: 3))
    }

    func testLegacyCartRequiresExplicitClaim() {
        let app = launch()
        XCTAssertTrue(app.buttons["In cart (0)"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Review old cart entries"].tap()
        XCTAssertTrue(app.navigationBars["Old cart entries"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Strawberries"].exists)
        app.buttons.matching(identifier: "Claim as mine").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Claimed as mine"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Groceries"].tap()
        app.buttons["In cart (1)"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Strawberries")).firstMatch.waitForExistence(timeout: 3))
    }

    func testOtherPurchaseKeepsOwnEntryUntilExplicitBuyAnyway() {
        let app = launch(purchaseNotice: true)
        XCTAssertTrue(app.buttons["In cart (1)"].waitForExistence(timeout: 8))
        app.buttons["In cart (1)"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.staticTexts["Already purchased"].waitForExistence(timeout: 3))
        app.buttons["Buy anyway"].tap()
        XCTAssertTrue(app.navigationBars["Check out"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Confirm"].isEnabled)
        let acknowledgement = app.switches["Already purchased. Buy anyway"]
        acknowledgement.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(acknowledgement.value as? String, "1")
        XCTAssertTrue(app.buttons["Confirm"].isEnabled)
        app.buttons["Confirm"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Your cart is empty in this view"].waitForExistence(timeout: 3))
    }

    func testPurchasedRememberedItemCanBeRequestedAgain() {
        let app = launch(purchaseNotice: true)
        XCTAssertTrue(app.buttons["In cart (1)"].waitForExistence(timeout: 8))
        XCTAssertFalse(groceryRow("Granola", app: app).exists)
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Granola")
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.catalogResult.", "Granola")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
        XCTAssertTrue(groceryRow("Granola", app: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["In cart (1)"].exists)
    }

    func testRetainedCartCanBeRemovedAfterHouseholdDisappears() {
        let app = launch(revoked: true)
        XCTAssertTrue(app.staticTexts["Waiting for your household"].waitForExistence(timeout: 8))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.staticTexts["Waiting for your household"].waitForExistence(timeout: 8))
        app.buttons["Saved personal carts"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Saved personal cart")).firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        app.buttons["Remove from my cart"].tap()
        XCTAssertTrue(app.staticTexts["Your cart is empty in this view"].waitForExistence(timeout: 3))
    }

    private func launch(purchaseNotice: Bool = false, revoked: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1"
        if purchaseNotice { app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_NOTICE"] = "1" }
        if revoked { app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_REVOKED"] = "1" }
        app.launch()
        return app
    }

    private func groceryRow(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.grocery.row.", "Edit \(name)")).firstMatch
    }
}
