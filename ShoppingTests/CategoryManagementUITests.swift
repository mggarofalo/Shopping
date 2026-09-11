import XCTest

final class CategoryManagementUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCategoryCreateStagedRenameAndImmediateUndoableRemoval() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingCategoryUITest-\(UUID().uuidString).sqlite").path
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Categories"].tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 3))
        app.buttons["shopping.categories.add"].tap()
        XCTAssertTrue(app.navigationBars["Add category"].waitForExistence(timeout: 2))
        let name = app.textFields["shopping.categories.name"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        name.typeText("Pantry")
        app.buttons["Save category"].tap()
        let pantry = categoryRow(named: "Pantry", in: app)
        XCTAssertTrue(pantry.waitForExistence(timeout: 2))

        pantry.tap()
        XCTAssertTrue(app.navigationBars["Rename category"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.categories.name"], with: "Canceled category")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(pantry.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled category"].exists)

        pantry.tap()
        replaceText(in: app.textFields["shopping.categories.name"], with: "Dry goods")
        app.buttons["Save category"].tap()
        let dryGoods = categoryRow(named: "Dry goods", in: app)
        XCTAssertTrue(dryGoods.waitForExistence(timeout: 2))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Category management"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        dryGoods.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(dryGoods.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Dry goods deleted"].waitForExistence(timeout: 2))
        app.buttons["shopping.categories.undoDelete"].tap()
        XCTAssertTrue(dryGoods.waitForExistence(timeout: 2))
        dryGoods.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(dryGoods.waitForExistence(timeout: 2))
        app.navigationBars["Categories"].buttons.firstMatch.tap()
        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
    }

    func testCategoryMergeAndDeleteMigrationUseAnchoredDestinationMenus() {
        let app = launchPopulated()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Categories"].tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 3))

        enterSelectionMode(app, navigationTitle: "Categories", identifier: "shopping.categories.select")
        app.staticTexts["Produce"].tap()
        let merge = app.buttons["shopping.categories.merge"]
        XCTAssertTrue(merge.isEnabled)
        merge.tap()
        app.buttons["Pantry"].tap()
        XCTAssertTrue(app.staticTexts["Produce merged into Pantry"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Produce"].exists)
        app.buttons["shopping.categories.undoDelete"].tap()
        XCTAssertTrue(categoryRow(named: "Produce", in: app).waitForExistence(timeout: 3))

        let produce = categoryRow(named: "Produce", in: app)
        produce.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Uncategorized"].waitForExistence(timeout: 2))
        app.buttons.matching(NSPredicate(format: "label == %@", "Pantry")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Produce merged into Pantry"].waitForExistence(timeout: 3))
        XCTAssertFalse(produce.exists)
    }

    func testCategoryBatchSelectAllPresentsOneRedDeleteConfirmation() {
        let app = launchPopulated()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Categories"].tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 3))
        enterSelectionMode(app, navigationTitle: "Categories", identifier: "shopping.categories.select")
        app.buttons["shopping.categories.selectAll"].tap()
        assertSelectedCountIsVisible(app)
        XCTAssertEqual(app.buttons["shopping.categories.selectAll"].label, "Deselect All")
        app.buttons["shopping.categories.selectAll"].tap()
        XCTAssertTrue(app.staticTexts["0 Selected"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["shopping.categories.batchDelete"].isEnabled)
        app.buttons["shopping.categories.selectAll"].tap()
        let delete = app.buttons["shopping.categories.batchDelete"]
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        let confirmation = app.sheets["Delete selected categories?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(confirmation.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "will be permanently deleted")
        ).firstMatch.exists)
        XCTAssertTrue(confirmation.buttons["Delete"].exists)
        confirmation.buttons["Delete"].tap()
        XCTAssertTrue(app.alerts["Batch update complete"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()
    }

    func testStoreAndCatalogBatchActionsReflectSelectedState() {
        let app = launchPopulated()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Stores"].tap()
        XCTAssertTrue(app.navigationBars["Stores"].waitForExistence(timeout: 3))
        enterSelectionMode(app, navigationTitle: "Stores", identifier: "shopping.stores.select")
        app.buttons["shopping.stores.selectAll"].tap()
        assertSelectedCountIsVisible(app)
        XCTAssertTrue(app.buttons["shopping.stores.batchArchive"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.stores.batchDelete"].exists)
        XCTAssertFalse(app.buttons["Move"].exists)
        app.buttons["shopping.stores.batchArchive"].tap()
        XCTAssertFalse(app.sheets["Archive selected stores?"].exists)
        XCTAssertTrue(app.alerts["Batch update complete"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()

        enterSelectionMode(app, navigationTitle: "Stores", identifier: "shopping.stores.select")
        app.buttons["shopping.stores.selectAll"].tap()
        XCTAssertTrue(app.buttons["shopping.stores.batchRestore"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["shopping.stores.batchArchive"].isEnabled)
        app.buttons["shopping.stores.batchRestore"].tap()
        XCTAssertFalse(app.sheets["Restore selected stores?"].exists)
        XCTAssertTrue(app.alerts["Batch update complete"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()

        app.navigationBars["Stores"].buttons.firstMatch.tap()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 3))
        enterSelectionMode(app, navigationTitle: "Catalog", identifier: "shopping.catalog.select")
        XCTAssertFalse(app.buttons["Add Bananas to list"].exists)
        app.buttons["shopping.catalog.selectAll"].tap()
        assertSelectedCountIsVisible(app)
        XCTAssertTrue(app.buttons["shopping.catalog.batchAdd"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.catalog.batchArchive"].exists)
        XCTAssertTrue(app.buttons["shopping.catalog.batchDelete"].exists)
        app.buttons["shopping.catalog.batchAdd"].tap()
        let addConfirmation = app.sheets["Add selected items to list?"]
        XCTAssertTrue(addConfirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(addConfirmation.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "in the cart will be needed again")
        ).firstMatch.exists)
        addConfirmation.buttons["Add to list"].tap()
        let feedback = app.staticTexts["shopping.feedback.message"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 3))
        XCTAssertTrue(feedback.label.contains("Needed again 1"))
    }

    func testCatalogAddFocusesExistingAndRequiresExplicitNeedAgainForCartedItem() {
        let app = launchPopulated()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 3))

        let existingRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Bananas")).firstMatch
        XCTAssertTrue(existingRow.waitForExistence(timeout: 3))
        existingRow.swipeLeft()
        app.buttons["Add to list"].tap()
        XCTAssertTrue(app.tabBars.buttons["Groceries"].isSelected)
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 3))
        app.buttons["shopping.grocery.cancel"].tap()

        app.tabBars.buttons["Catalog"].tap()
        let carted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Strawberries")).firstMatch
        XCTAssertTrue(carted.waitForExistence(timeout: 3))
        carted.swipeLeft()
        app.buttons["Add to list"].tap()
        let confirmation = app.sheets["Need Strawberries again?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        confirmation.buttons["Need again"].tap()
        XCTAssertTrue(app.buttons["View"].waitForExistence(timeout: 3))
        app.buttons["View"].tap()
        XCTAssertTrue(app.tabBars.buttons["Groceries"].isSelected)
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 3))
    }

    func testSelectionControlsStayVisibleAtAccessibilityTextSize() {
        let app = launchPopulated(accessibilitySize: true)

        app.tabBars.buttons["Settings"].tap()
        app.buttons["Categories"].tap()
        enterSelectionMode(app, navigationTitle: "Categories", identifier: "shopping.categories.select")
        app.buttons["shopping.categories.selectAll"].tap()
        XCTAssertTrue(app.buttons["shopping.categories.batchDelete"].isHittable)
        app.buttons["Done"].tap()

        app.navigationBars["Categories"].buttons.firstMatch.tap()
        app.buttons["Stores"].tap()
        enterSelectionMode(app, navigationTitle: "Stores", identifier: "shopping.stores.select")
        app.buttons["shopping.stores.selectAll"].tap()
        XCTAssertTrue(app.buttons["shopping.stores.batchArchive"].isHittable)
        XCTAssertTrue(app.buttons["shopping.stores.batchDelete"].isHittable)
        app.buttons["Done"].tap()

        app.navigationBars["Stores"].buttons.firstMatch.tap()
        app.tabBars.buttons["Catalog"].tap()
        enterSelectionMode(app, navigationTitle: "Catalog", identifier: "shopping.catalog.select")
        app.buttons["shopping.catalog.selectAll"].tap()
        XCTAssertTrue(app.buttons["shopping.catalog.batchAdd"].isHittable)
        XCTAssertTrue(app.buttons["shopping.catalog.batchDelete"].isHittable)
    }

    func testTouchAndHoldOffersSelectThenKeepsNativeMultiSelection() {
        let app = launchPopulated()

        app.tabBars.buttons["Settings"].tap()
        app.buttons["Categories"].tap()
        categoryRow(named: "Produce", in: app).press(forDuration: 0.7)
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "shopping.categories.contextSelect.")
        ).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 Selected"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.categories.batchEdit"].isEnabled)
        app.staticTexts["Pantry"].tap()
        XCTAssertTrue(app.staticTexts["2 Selected"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["shopping.categories.batchEdit"].isEnabled)
        XCTAssertTrue(app.buttons["shopping.categories.batchDelete"].isEnabled)
        app.buttons["Done"].tap()

        app.navigationBars["Categories"].buttons.firstMatch.tap()
        app.buttons["Stores"].tap()
        storeRow(named: "Costco", in: app).press(forDuration: 0.7)
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "shopping.stores.contextSelect.")
        ).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 Selected"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.stores.batchEdit"].isEnabled)
        app.buttons["Done"].tap()

        app.navigationBars["Stores"].buttons.firstMatch.tap()
        app.tabBars.buttons["Catalog"].tap()
        app.staticTexts["Chipotles in adobo"].press(forDuration: 0.7)
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "shopping.catalog.contextSelect.")
        ).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 Selected"].waitForExistence(timeout: 2))
        let granola = app.staticTexts["Granola"]
        XCTAssertTrue(granola.waitForExistence(timeout: 2))
        if !granola.isHittable { app.swipeUp() }
        XCTAssertTrue(waitForHittable(granola))
        granola.tap()
        XCTAssertTrue(app.staticTexts["2 Selected"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.catalog.batchAdd"].isEnabled)
        XCTAssertTrue(app.buttons["shopping.catalog.batchArchive"].isEnabled)
        XCTAssertTrue(app.buttons["shopping.catalog.batchDelete"].isEnabled)
    }

    private func launchPopulated(accessibilitySize: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingBatchUITest-\(UUID().uuidString).sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        return app
    }

    private func enterSelectionMode(_ app: XCUIApplication, navigationTitle: String, identifier: String) {
        let select = app.buttons[identifier]
        XCTAssertTrue(select.waitForExistence(timeout: 2), "Select must be visible in \(navigationTitle)")
        XCTAssertTrue(select.isHittable, "Select must not be hidden in an overflow menu")
        select.tap()
        XCTAssertTrue(app.buttons["Select All"].waitForExistence(timeout: 2))
    }

    private func categoryRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func storeRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    private func assertSelectedCountIsVisible(_ app: XCUIApplication) {
        let selectedTitle = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH %@ AND label != %@", " Selected", "0 Selected")
        ).firstMatch
        XCTAssertTrue(selectedTitle.waitForExistence(timeout: 2))
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 2) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(text)
    }
}
