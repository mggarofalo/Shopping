import XCTest

final class GroceryEditingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRememberedDraftCancelAndAtomicSaveSurviveRelaunch() {
        let app = launchApp()
        openAdd(in: app)
        let remembered = app.switches["shopping.grocery.remembered"]
        XCTAssertEqual(remembered.value as? String, "1")
        enterName("Coconut yogurt", in: app)
        setSwitch(app.switches["Any store"], on: true, app: app)
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered groceries"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Groceries"].tap()

        openAdd(in: app)
        enterName("Coconut yogurt", in: app)
        setSwitch(app.switches["Any store"], on: true, app: app)
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(groceryRow(named: "Coconut yogurt", app: app).waitForExistence(timeout: 3))
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["Coconut yogurt"].waitForExistence(timeout: 2))

        app.terminate()
        app.launch()
        app.tabBars.buttons["Groceries"].tap()
        let row = groceryRow(named: "Coconut yogurt", app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.grocery.quantity"].value as? String, "1")
        attachScreenshot(named: "Remembered grocery editor", app: app)
    }

    func testActiveMatchFocusPreservesUrgencyAndExplicitNeedAgainUncarts() {
        let app = launchApp(fixture: "populated")
        openAdd(in: app)
        enterName("Granola", in: app)
        let match = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.activeMatch.", "Granola"
        )).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 2))
        match.tap()
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.grocery.quantity"].value as? String, "1")
        XCTAssertEqual(app.textFields["shopping.grocery.purchaseNotes"].value as? String, "Low sugar")
        XCTAssertTrue(app.segmentedControls["shopping.grocery.urgency"].buttons["Urgent"].isSelected)
        app.buttons["shopping.grocery.cancel"].tap()

        openAdd(in: app)
        enterName("Strawberries", in: app)
        app.buttons["Edit current Strawberries"].tap()
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Carted (1)"))
            .firstMatch.waitForExistence(timeout: 3))

        openAdd(in: app)
        enterName("Strawberries", in: app)
        let needAgain = app.buttons["Need again Strawberries"]
        XCTAssertTrue(needAgain.waitForExistence(timeout: 2))
        needAgain.tap()
        let carted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Carted (0)")).firstMatch
        XCTAssertTrue(carted.waitForExistence(timeout: 3))
        reveal(groceryRow(named: "Strawberries", app: app), in: app)
    }

    func testOneTimeIndividualRemovalAndUndoDoNotCreateCatalogKnowledge() {
        let app = launchApp()
        openAdd(in: app)
        enterName("Single-use ice", in: app)
        setSwitch(app.switches["shopping.grocery.remembered"], on: false, app: app)
        setSwitch(app.switches["Any store"], on: true, app: app)
        app.buttons["shopping.grocery.save"].tap()
        let row = groceryRow(named: "Single-use ice", app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        let remove = app.buttons["shopping.grocery.remove"]
        reveal(remove, in: app)
        remove.tap()
        let confirm = app.alerts.buttons["shopping.grocery.confirmRemove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()
        XCTAssertTrue(app.buttons["shopping.grocery.undoRemove"].waitForExistence(timeout: 3))
        XCTAssertFalse(row.exists)
        app.buttons["shopping.grocery.undoRemove"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        XCTAssertTrue(groceryRow(named: "Single-use ice", app: app).waitForExistence(timeout: 3))
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered groceries"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Single-use ice"].exists)
    }

    func testStoreDefaultDoesNotOverwriteAnExistingItemsRules() {
        let app = launchApp(fixture: "populated")
        app.buttons["shopping.store.menu"].tap()
        app.buttons["Costco"].tap()
        openAdd(in: app)
        enterName("Bananas", in: app)
        let match = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.activeMatch.", "Bananas"
        )).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 2))
        match.tap()
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        let anyStore = app.switches["Any store"]
        reveal(anyStore, in: app)
        XCTAssertEqual(anyStore.value as? String, "1")
        let costco = app.switches["Costco"]
        reveal(costco, in: app)
        XCTAssertEqual(costco.value as? String, "0")
        app.buttons["shopping.grocery.cancel"].tap()

        openAdd(in: app)
        enterName("New Costco oats", in: app)
        reveal(anyStore, in: app)
        XCTAssertEqual(anyStore.value as? String, "0")
        reveal(costco, in: app)
        XCTAssertEqual(costco.value as? String, "1")
        attachScreenshot(named: "New grocery uses selected store", app: app)
        app.buttons["shopping.grocery.cancel"].tap()
    }

    func testCartedNeedAgainOffersShowAllWhenCurrentStoreHidesTheGrocery() {
        let app = launchApp(fixture: "populated")
        app.buttons["shopping.store.menu"].tap()
        app.buttons["Publix"].tap()
        let carted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Carted (1)")).firstMatch
        XCTAssertTrue(carted.waitForExistence(timeout: 2))
        carted.tap()
        XCTAssertTrue(app.navigationBars["Carted"].waitForExistence(timeout: 2))
        groceryRow(named: "Strawberries", app: app).tap()
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Carted"].waitForExistence(timeout: 2))
        XCTAssertTrue(groceryRow(named: "Strawberries", app: app).exists)
        app.buttons["Need again Strawberries"].tap()
        XCTAssertTrue(app.staticTexts["Nothing carted"].waitForExistence(timeout: 3))
        app.navigationBars["Carted"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 3))
        let showAll = app.buttons["shopping.grocery.showAll"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 3))
        showAll.tap()
        reveal(groceryRow(named: "Strawberries", app: app), in: app)
        XCTAssertFalse(showAll.exists)
    }

    private func launchApp(fixture: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingEditingUITest-\(UUID().uuidString).sqlite").path
        if let fixture { app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture }
        app.launch()
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        return app
    }

    private func openAdd(in app: XCUIApplication) {
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add grocery"].waitForExistence(timeout: 2))
    }

    private func enterName(_ name: String, in app: XCUIApplication) {
        let field = app.textFields["shopping.grocery.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText(name)
    }

    private func groceryRow(named name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.row.", name
        )).firstMatch
    }

    private func setSwitch(_ toggle: XCUIElement, on: Bool, app: XCUIApplication) {
        reveal(toggle, in: app)
        if (toggle.value as? String == "1") != on {
            let control = toggle.switches.firstMatch
            (control.exists ? control : toggle).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
