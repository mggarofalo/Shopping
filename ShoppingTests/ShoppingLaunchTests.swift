import XCTest

final class ShoppingLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsEmptyGroceriesAndConnectedTabs() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shopping.addGrocery"].exists)
        XCTAssertTrue(app.tabBars.buttons["Catalog"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        attachScreenshot(named: "Empty Groceries", app: app)

        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
    }

    func testPopulatedCostcoNavigationAtAccessibilitySize() {
        let app = launchApp(fixture: "populated", accessibilitySize: true)
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        let storeMenu = app.buttons["shopping.store.menu"]
        XCTAssertTrue(storeMenu.waitForExistence(timeout: 3))
        storeMenu.tap()
        let costco = app.buttons["Costco"]
        XCTAssertTrue(costco.waitForExistence(timeout: 2))
        costco.tap()
        XCTAssertTrue(staticText(named: "Must buy here", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.filters"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Carted")).firstMatch.exists)
        let flexibleSection = staticText(named: "Flexible here", in: app)
        for _ in 0..<8 where !flexibleSection.exists || !flexibleSection.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(flexibleSection.exists)
        XCTAssertTrue(flexibleSection.isHittable)
        attachScreenshot(named: "Populated Costco Accessibility Large", app: app)
    }

    func testOneTimeAddSavesWithoutStoreSetupAndDoesNotPolluteCatalog() {
        let app = launchApp()
        openOneTimeAdd(in: app, groceryName: "Fresh basil")
        let anyStore = app.switches["Any store"]
        for _ in 0..<8 where !anyStore.exists || !anyStore.isHittable { app.swipeUp() }
        setSwitch(named: "Any store", on: true, in: app)
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(app.staticTexts["Fresh basil"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered groceries"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Fresh basil"].exists)
    }

    func testStoreManagementStagesRenameAndSupportsArchiveRestore() {
        let app = launchApp()
        openStoreManagement(in: app)

        let createName = app.textFields["shopping.stores.createName"]
        XCTAssertTrue(createName.waitForExistence(timeout: 2))
        createName.tap()
        createName.typeText("Neighborhood Market")
        app.buttons["Save store"].tap()
        XCTAssertTrue(app.staticTexts["Neighborhood Market"].waitForExistence(timeout: 2))

        app.buttons["Rename"].tap()
        XCTAssertTrue(app.navigationBars["Rename store"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.stores.renameName"], with: "Canceled Market")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Neighborhood Market"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled Market"].exists)

        app.buttons["Rename"].tap()
        XCTAssertTrue(app.navigationBars["Rename store"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.stores.renameName"], with: "Local Market")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Local Market"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Neighborhood Market"].exists)

        app.buttons["Archive"].tap()
        XCTAssertTrue(app.staticTexts["Archived"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Restore"].exists)
        attachScreenshot(named: "Store Management Archived", app: app)
        app.buttons["Restore"].tap()
        XCTAssertFalse(app.staticTexts["Archived"].exists)
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 2))
    }

    func testCancelingInlineStoreAndParentAddCreatesNeitherStoreNorNeed() {
        let app = launchApp()
        openOneTimeAdd(in: app, groceryName: "Canceled grocery")
        revealInlineAddStore(in: app).tap()
        XCTAssertTrue(app.navigationBars["Add store"].waitForExistence(timeout: 2))
        let storeName = app.textFields["shopping.tags.storeName"]
        storeName.tap()
        storeName.typeText("Canceled store")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Add grocery"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled store"].exists)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
        openStoreManagement(in: app)
        XCTAssertFalse(app.staticTexts["Canceled store"].exists)
    }

    func testSavingInlineStoreSelectsItButParentCancelCreatesNoNeed() {
        let app = launchApp()
        openOneTimeAdd(in: app, groceryName: "Canceled tagged grocery")
        revealInlineAddStore(in: app).tap()
        XCTAssertTrue(app.navigationBars["Add store"].waitForExistence(timeout: 2))
        let storeName = app.textFields["shopping.tags.storeName"]
        storeName.tap()
        storeName.typeText("Corner Shop")
        app.buttons["Save store"].tap()

        XCTAssertTrue(app.navigationBars["Add grocery"].waitForExistence(timeout: 2))
        let selectedStore = app.switches["Corner Shop"]
        XCTAssertTrue(selectedStore.waitForExistence(timeout: 2))
        XCTAssertEqual(selectedStore.value as? String, "1")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))

        openStoreManagement(in: app)
        XCTAssertTrue(app.staticTexts["Corner Shop"].waitForExistence(timeout: 2))
    }

    func testCategoryAndUrgentFilterChipsNarrowThenBroadenTheExistingGroceries() {
        let app = launchApp(fixture: "populated")
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 3))
        revealGrocery(named: "Chipotles in adobo", in: app)

        app.buttons["shopping.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 2))
        setSwitch(named: "Urgent only", on: true, in: app)
        let pantry = app.buttons["Pantry"]
        XCTAssertTrue(pantry.waitForExistence(timeout: 2))
        pantry.tap()
        dismissGroceryFilters(in: app)

        XCTAssertTrue(app.buttons["Remove Urgent filter"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Remove Pantry filter"].exists)
        attachScreenshot(named: "Pantry Urgent Filter Chips", app: app)
        revealGrocery(named: "Granola", in: app)
        assertNoGrocery(named: "Chipotles in adobo", in: app)

        app.buttons["Remove Urgent filter"].tap()
        revealGrocery(named: "Chipotles in adobo", in: app)
        XCTAssertTrue(app.buttons["Remove Pantry filter"].exists)
        revealGrocery(named: "Granola", in: app)

        app.buttons["Remove Pantry filter"].tap()
        revealGrocery(named: "Bananas", in: app)
        revealGrocery(named: "Granola", in: app)
    }

    func testIncludedAndExcludedLiteralTagChipsGiveExclusionPrecedence() {
        let app = launchApp(fixture: "populated")
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 3))

        app.buttons["shopping.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 2))
        setStoreTag(named: "Costco", in: .include, on: true, app: app)
        setStoreTag(named: "Costco", in: .exclude, on: true, app: app)
        dismissGroceryFilters(in: app)

        XCTAssertTrue(app.buttons["Remove Tagged Costco filter"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Remove Not tagged Costco filter"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["No matching groceries"].exists)

        app.buttons["Remove Not tagged Costco filter"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Remove Tagged Costco filter"].exists)
    }

    func testCatalogEditorCancelAndSavedAnyStoreItemDoNotCreateGroceries() {
        let app = launchApp()
        openCatalog(in: app)

        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Canceled catalog item")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Canceled catalog item"].waitForExistence(timeout: 2))

        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Reusable coffee")
        replaceText(in: app.textFields["shopping.catalog.notes"], with: "Whole bean")
        let anyStore = app.switches["Any store"]
        XCTAssertTrue(anyStore.waitForExistence(timeout: 2))
        let anyStoreControl = anyStore.switches.firstMatch
        (anyStoreControl.exists ? anyStoreControl : anyStore).tap()
        XCTAssertEqual(anyStore.value as? String, "1")
        let save = app.buttons["shopping.catalog.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Reusable coffee"].waitForExistence(timeout: 2))

        app.staticTexts["Reusable coffee"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Canceled coffee edit")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Reusable coffee"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled coffee edit"].exists)

        app.staticTexts["Reusable coffee"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Saved coffee edit")
        app.buttons["shopping.catalog.save"].tap()
        XCTAssertTrue(app.staticTexts["Saved coffee edit"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Saved coffee edit"].exists)
    }

    func testCatalogArchiveFilterAndRestorePreservesActiveGrocery() {
        let app = launchApp(fixture: "populated")
        openCatalog(in: app)
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 3))
        app.staticTexts["Granola"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        app.buttons["shopping.catalog.archive"].tap()
        tapArchiveStateConfirmation(in: "Archive this catalog item?", app: app)
        XCTAssertFalse(app.staticTexts["Granola"].waitForExistence(timeout: 2))

        app.buttons["shopping.catalog.filters"].tap()
        enableArchivedItems(in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 2))

        app.staticTexts["Granola"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        app.buttons["shopping.catalog.archive"].tap()
        XCTAssertFalse(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))

        app.buttons["shopping.catalog.filters"].tap()
        resetCatalogFilters(in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 2))
    }

    func testDirtyArchivedCatalogRestoreConfirmationCancelKeepsEditorDraft() {
        let app = launchApp(fixture: "populated")
        openCatalog(in: app)
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 3))
        app.staticTexts["Granola"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        app.buttons["shopping.catalog.archive"].tap()
        tapArchiveStateConfirmation(in: "Archive this catalog item?", app: app)

        app.buttons["shopping.catalog.filters"].tap()
        enableArchivedItems(in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 2))
        app.staticTexts["Granola"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Draft granola")
        replaceText(in: app.textFields["shopping.catalog.notes"], with: "Draft note")
        let draftName = app.textFields["shopping.catalog.name"].value as? String
        let draftNotes = app.textFields["shopping.catalog.notes"].value as? String
        XCTAssertNotEqual(draftName, "Granola")
        XCTAssertFalse(draftNotes?.isEmpty ?? true)
        app.buttons["shopping.catalog.archive"].tap()
        XCTAssertTrue(app.staticTexts["Restore this catalog item?"].waitForExistence(timeout: 2))

        let restoreAlert = app.alerts["Restore this catalog item?"]
        XCTAssertTrue(restoreAlert.waitForExistence(timeout: 2))
        let keepEditing = restoreAlert.buttons["Keep editing"].firstMatch
        XCTAssertTrue(keepEditing.waitForExistence(timeout: 2))
        keepEditing.tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.catalog.name"].value as? String, draftName)
        XCTAssertEqual(app.textFields["shopping.catalog.notes"].value as? String, draftNotes)
    }

    func testCatalogFilterResetAtAccessibilitySizeDoesNotChangeGroceries() {
        let app = launchApp(fixture: "populated", accessibilitySize: true)
        openCatalog(in: app)
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 3))
        app.buttons["shopping.catalog.filters"].tap()
        enableArchivedItems(in: app)
        resetCatalogFilters(in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 2))
        attachScreenshot(named: "Populated Catalog Accessibility Large", app: app)

        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 2))
        let bananas = app.staticTexts["Bananas"]
        for _ in 0..<6 where !bananas.exists { app.swipeUp() }
        XCTAssertTrue(bananas.waitForExistence(timeout: 2))
    }

    private func revealInlineAddStore(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["shopping.tags.addStore"]
        for _ in 0..<8 {
            let top = app.navigationBars["Add grocery"].frame.maxY
            let bottom = app.keyboards.firstMatch.exists
                ? app.keyboards.firstMatch.frame.minY - 60 : app.frame.maxY - 40
            // iOS 18 can report an offscreen link as hittable behind the keyboard.
            // Its keyboard frame excludes the prediction bar, so leave room above it.
            if button.exists && button.isHittable && button.frame.minY >= top && button.frame.maxY <= bottom {
                return button
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: bottom - 24))
            let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: top + 24))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Inline Add store did not become visible above the keyboard")
        return button
    }

    private func launchApp(fixture: String? = nil, accessibilitySize: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingUITest-\(UUID().uuidString).sqlite").path
        if let fixture { app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture }
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        }
        app.launch()
        return app
    }

    private func openStoreManagement(in app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        app.buttons["Stores"].tap()
        XCTAssertTrue(app.navigationBars["Stores"].waitForExistence(timeout: 2))
    }

    private func openCatalog(in app: XCUIApplication) {
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 2))
    }

    private enum StoreTagSection: Int {
        case include = 0
        case exclude = 1

        var header: String {
            switch self {
            case .include: "Include a store tag"
            case .exclude: "Exclude a store tag"
            }
        }
    }

    private func dismissGroceryFilters(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Filters"].exists)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Filters"].waitForExistence(timeout: 2))
    }

    private func setSwitch(named name: String, on: Bool, in app: XCUIApplication) {
        let toggle = app.switches[name]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        if (toggle.value as? String == "1") != on {
            let control = toggle.switches.firstMatch
            (control.exists ? control : toggle).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    private func setStoreTag(
        named name: String,
        in section: StoreTagSection,
        on: Bool,
        app: XCUIApplication
    ) {
        XCTAssertTrue(app.navigationBars["Filters"].exists)
        let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", section.header)).firstMatch
        XCTAssertTrue(header.exists)
        let tags = app.switches.matching(NSPredicate(format: "label == %@", name))
        let toggle = tags.element(boundBy: section.rawValue)
        for _ in 0..<6 where !toggle.exists || !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertGreaterThanOrEqual(tags.count, section.rawValue + 1)
        XCTAssertTrue(toggle.isHittable)
        if (toggle.value as? String == "1") != on {
            let control = toggle.switches.firstMatch
            (control.exists ? control : toggle).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    private func revealGrocery(named name: String, in app: XCUIApplication) {
        let grocery = staticText(named: name, in: app)
        for _ in 0..<6 where !grocery.exists {
            app.swipeUp()
        }
        XCTAssertTrue(grocery.waitForExistence(timeout: 2), "Expected grocery \(name) to be visible")
    }

    private func assertNoGrocery(named name: String, in app: XCUIApplication) {
        let grocery = staticText(named: name, in: app)
        for _ in 0..<6 where !grocery.exists {
            app.swipeUp()
        }
        XCTAssertFalse(grocery.exists, "Did not expect grocery \(name) after filtering")
    }

    private func enableArchivedItems(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Catalog filters"].waitForExistence(timeout: 2))
        let archived = app.switches["Archived items"]
        for _ in 0..<3 where !archived.exists || !archived.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(archived.waitForExistence(timeout: 2))
        XCTAssertTrue(archived.isHittable)
        let archivedControl = archived.switches.firstMatch
        (archivedControl.exists ? archivedControl : archived).tap()
        XCTAssertEqual(archived.value as? String, "1")
    }

    private func tapArchiveStateConfirmation(in title: String, app: XCUIApplication) {
        let confirmation = app.alerts[title]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        let action = confirmation.buttons["shopping.catalog.confirmArchiveState"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 2))
        action.tap()
        XCTAssertFalse(confirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.navigationBars["Edit catalog item"].exists)
    }

    private func resetCatalogFilters(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Catalog filters"].waitForExistence(timeout: 2))
        let reset = app.buttons["shopping.catalog.reset"].firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 2))
        reset.tap()
    }

    private func openOneTimeAdd(in app: XCUIApplication, groceryName: String) {
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add grocery"].waitForExistence(timeout: 2))
        setSwitch(named: "shopping.grocery.remembered", on: false, in: app)
        let name = app.textFields["shopping.grocery.name"]
        name.tap()
        name.typeText(groceryName)
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        if let remainingText = field.value as? String {
            for _ in remainingText {
                field.typeKey(.delete, modifierFlags: [])
            }
        }
        field.typeText(text)
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func staticText(named label: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }
}
