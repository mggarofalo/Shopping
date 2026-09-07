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
        XCTAssertTrue(shoppingHeading("Only buy here", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.filters"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "In cart")).firstMatch.exists)
        let flexibleSection = shoppingHeading("Can buy here", in: app)
        for _ in 0..<8 where !flexibleSection.exists || !flexibleSection.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(flexibleSection.exists)
        XCTAssertTrue(flexibleSection.isHittable)
        attachScreenshot(named: "Populated Costco Accessibility Large", app: app)
    }

    func testCompactStoreGroupsOmitRepeatedPurchaseRulesInBothAppearances() {
        for appearance in ["light", "dark"] {
            let app = launchApp(fixture: "populated", appearance: appearance)
            XCTAssertFalse(shoppingHeading("Only buy here", in: app).exists)
            XCTAssertFalse(shoppingHeading("Can buy here", in: app).exists)
            XCTAssertFalse(app.staticTexts["Needs store"].exists)
            app.buttons["shopping.store.menu"].tap()
            app.buttons["Costco"].tap()
            XCTAssertTrue(shoppingHeading("Only buy here", in: app).waitForExistence(timeout: 2))
            let canBuy = shoppingHeading("Can buy here", in: app)
            reveal(canBuy, in: app)
            XCTAssertTrue(canBuy.isHittable)
            XCTAssertFalse(app.staticTexts["Pantry"].exists)
            XCTAssertFalse(app.staticTexts["Produce"].exists)
            XCTAssertFalse(app.staticTexts["Buy at any store"].exists)
            XCTAssertFalse(app.staticTexts["Only buy at Costco"].exists)
            XCTAssertFalse(app.buttons["Edit Chipotles in adobo"].exists)
            XCTAssertFalse(app.buttons["Edit Local honey"].exists)
            attachScreenshot(named: "Compact Costco \(appearance)", app: app)
            app.terminate()
        }
    }

    func testOneTimeAddSavesWithoutStoreSetupAndDoesNotPolluteCatalog() {
        let app = launchApp()
        openOneTimeAdd(in: app, groceryName: "Fresh basil")
        XCTAssertTrue(app.buttons["shopping.grocery.save"].isEnabled)
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(app.staticTexts["Fresh basil"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered items"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Fresh basil"].exists)
    }

    func testStoreManagementStagesRenameAndDeletesUnreferencedStore() {
        let app = launchApp()
        openStoreManagement(in: app)

        app.buttons["shopping.stores.add"].tap()
        XCTAssertTrue(app.navigationBars["Add store"].waitForExistence(timeout: 2))
        let createName = app.textFields["shopping.stores.name"]
        XCTAssertTrue(createName.waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        createName.typeText("Neighborhood Market")
        app.buttons["Save store"].tap()
        XCTAssertTrue(app.staticTexts["Neighborhood Market"].waitForExistence(timeout: 2))

        app.buttons["Rename Neighborhood Market"].tap()
        XCTAssertTrue(app.navigationBars["Rename store"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.stores.name"], with: "Canceled Market")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Neighborhood Market"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled Market"].exists)

        app.buttons["Rename Neighborhood Market"].tap()
        XCTAssertTrue(app.navigationBars["Rename store"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.stores.name"], with: "Local Market")
        app.buttons["Save store"].tap()
        XCTAssertTrue(app.staticTexts["Local Market"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Neighborhood Market"].exists)

        app.buttons["Delete Local Market"].tap()
        XCTAssertTrue(app.staticTexts["Delete Local Market?"].waitForExistence(timeout: 2))
        app.buttons["Delete store"].tap()
        XCTAssertFalse(app.staticTexts["Local Market"].waitForExistence(timeout: 2))
    }

    func testStoreManagementArchivesReferencedStoreHidesItAndResetsSelectedStore() {
        let app = launchApp(fixture: "populated")
        app.buttons["shopping.store.menu"].tap()
        app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Costco", "shopping.store.menu")
        ).firstMatch.tap()
        XCTAssertTrue(app.buttons["shopping.store.clear"].waitForExistence(timeout: 2))

        openStoreManagement(in: app)
        XCTAssertFalse(app.staticTexts["Neighborhood Market (closed)"].exists)
        app.buttons["Delete Costco"].tap()
        XCTAssertTrue(app.staticTexts["Archive Costco?"].waitForExistence(timeout: 2))
        app.buttons["Archive store"].tap()
        XCTAssertFalse(app.buttons["Delete Costco"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.buttons["shopping.store.all"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.store.all"].isSelected)
        XCTAssertFalse(app.buttons["shopping.store.clear"].exists)
        app.buttons["shopping.store.menu"].tap()
        XCTAssertFalse(app.buttons["Costco"].waitForExistence(timeout: 2))
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
        XCTAssertTrue(app.navigationBars["Add item"].waitForExistence(timeout: 2))
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

        XCTAssertTrue(app.navigationBars["Add item"].waitForExistence(timeout: 2))
        let selectedStore = app.buttons["Corner Shop"]
        XCTAssertTrue(selectedStore.waitForExistence(timeout: 2))
        XCTAssertEqual(selectedStore.value as? String, "Selected")
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
        revealGrocery(named: "Granola", in: app, towardTop: true)
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
        let anyStore = app.buttons["shopping.purchase.anyStore"]
        XCTAssertTrue(anyStore.waitForExistence(timeout: 2))
        let anyStoreControl = anyStore.switches.firstMatch
        (anyStoreControl.exists ? anyStoreControl : anyStore).tap()
        XCTAssertEqual(anyStore.value as? String, "Selected")
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
        let catalogRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.catalog.item."))
            .containing(.staticText, identifier: "Granola").firstMatch
        reveal(catalogRow, in: app)
        catalogRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        reveal(app.buttons["shopping.catalog.archive"], in: app)
        app.buttons["shopping.catalog.archive"].tap()
        tapArchiveStateConfirmation(in: "Archive this catalog item?", app: app)
        XCTAssertFalse(app.staticTexts["Granola"].waitForExistence(timeout: 2))

        app.buttons["shopping.catalog.filters"].tap()
        enableArchivedItems(in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 2))

        app.staticTexts["Granola"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))
        reveal(app.buttons["shopping.catalog.archive"], in: app)
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
        reveal(app.buttons["shopping.catalog.archive"], in: app)
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
        reveal(app.buttons["shopping.catalog.archive"], in: app)
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
        let catalogGranola = app.staticTexts["Granola"]
        reveal(catalogGranola, in: app)
        XCTAssertTrue(catalogGranola.waitForExistence(timeout: 3))
        let filters = app.buttons["shopping.catalog.filters"]
        for _ in 0..<8 where !filters.exists || !filters.isHittable {
            app.collectionViews["shopping.catalog.list"].swipeDown()
        }
        XCTAssertTrue(filters.waitForExistence(timeout: 3))
        XCTAssertTrue(filters.isHittable)
        filters.tap()
        enableArchivedItems(in: app)
        resetCatalogFilters(in: app)
        app.buttons["Done"].tap()
        reveal(catalogGranola, in: app)
        XCTAssertTrue(catalogGranola.waitForExistence(timeout: 2))
        attachScreenshot(named: "Populated Catalog Accessibility Large", app: app)

        app.tabBars.buttons["Groceries"].tap()
        let groceryGranola = app.staticTexts["Granola"]
        reveal(groceryGranola, in: app)
        XCTAssertTrue(groceryGranola.waitForExistence(timeout: 2))
        let bananas = app.buttons["Edit Bananas"]
        for _ in 0..<6 where !bananas.exists { app.swipeUp() }
        XCTAssertTrue(bananas.waitForExistence(timeout: 2))
    }

    private func revealInlineAddStore(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["shopping.tags.addStore"]
        for _ in 0..<8 {
            let top = app.navigationBars["Add item"].frame.maxY
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

    private func launchApp(fixture: String? = nil, accessibilitySize: Bool = false, appearance: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingUITest-\(UUID().uuidString).sqlite").path
        if let fixture { app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture }
        if let appearance { app.launchArguments += ["-shopping.appearance", appearance] }
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

    private enum StoreTagSection {
        case include
        case exclude

        var header: String {
            switch self {
            case .include: "Include a store tag"
            case .exclude: "Exclude a store tag"
            }
        }

        var identifierPrefix: String {
            switch self {
            case .include: "shopping.filters.include."
            case .exclude: "shopping.filters.exclude."
            }
        }
    }

    private func dismissGroceryFilters(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Filters"].exists)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Filters"].waitForExistence(timeout: 2))
    }

    private func setSwitch(named name: String, on: Bool, in app: XCUIApplication) {
        if name == "Any store" {
            let pill = app.buttons["shopping.purchase.anyStore"]
            reveal(pill, in: app)
            if (pill.value as? String == "Selected") != on { pill.tap() }
            XCTAssertEqual(pill.value as? String, on ? "Selected" : "Not selected")
            return
        }
        let toggle = app.switches[name]
        reveal(toggle, in: app)
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
        let header = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@", section.header)
        ).firstMatch
        reveal(header, in: app)
        XCTAssertTrue(header.exists)
        let tags = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", section.identifierPrefix, name
        ))
        let pill = tags.firstMatch
        reveal(pill, in: app)
        XCTAssertEqual(tags.count, 1)
        XCTAssertTrue(pill.isHittable)
        if (pill.value as? String == "Selected") != on { pill.tap() }
        XCTAssertEqual(pill.value as? String, on ? "Selected" : "Not selected")
    }

    private func shoppingHeading(_ title: String, in app: XCUIApplication) -> XCUIElement {
        // iOS 18 uppercases native section headers; iOS 26 keeps sentence case.
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch
    }

    private func revealGrocery(named name: String, in app: XCUIApplication, towardTop: Bool = false) {
        let grocery = app.buttons["Edit \(name)"]
        for _ in 0..<6 where !grocery.exists {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(grocery.waitForExistence(timeout: 2), "Expected grocery \(name) to be visible")
    }

    private func assertNoGrocery(named name: String, in app: XCUIApplication) {
        let grocery = app.buttons["Edit \(name)"]
        for _ in 0..<6 where !grocery.exists {
            app.swipeUp()
        }
        XCTAssertFalse(grocery.exists, "Did not expect grocery \(name) after filtering")
    }

    private func enableArchivedItems(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Catalog filters"].waitForExistence(timeout: 2))
        let archived = app.buttons["shopping.catalog.archived"]
        for _ in 0..<3 where !archived.exists || !archived.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(archived.waitForExistence(timeout: 2))
        XCTAssertTrue(archived.isHittable)
        archived.tap()
        XCTAssertEqual(archived.value as? String, "Selected")
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

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            let appFrame = app.frame
            let navigationBar = app.navigationBars.firstMatch
            let navigationFrame = navigationBar.frame
            guard usable(appFrame), usable(navigationFrame) else { continue }
            let targetIsInNavigationBar = contains(element, in: navigationBar)
            let fixedScope = app.otherElements["shopping.grocery.fixedScope"]
            let targetIsInFixedScope = contains(element, in: fixedScope)
            let fixedScopeFrame = fixedScope.exists && fixedScope.isHittable
                && !targetIsInNavigationBar && !targetIsInFixedScope ? fixedScope.frame : nil
            if let fixedScopeFrame, !usable(fixedScopeFrame) { continue }
            let contentTop = max(navigationFrame.maxY, fixedScopeFrame?.maxY ?? navigationFrame.maxY)
            let top = targetIsInNavigationBar ? appFrame.minY : contentTop
            let keyboard = app.keyboards.firstMatch
            let keyboardFrame = keyboard.exists ? keyboard.frame : nil
            if let keyboardFrame, !usable(keyboardFrame) { continue }
            let tabBar = app.tabBars.firstMatch
            let tabBarFrame = tabBar.exists && tabBar.isHittable ? tabBar.frame : nil
            if let tabBarFrame, !usable(tabBarFrame) { continue }
            let lowerSystemBound = keyboardFrame.map { $0.minY - 60 }
                ?? tabBarFrame.map(\.minY) ?? appFrame.maxY
            let feedback = app.otherElements["shopping.grocery.feedback"]
            let targetIsInFeedback = contains(element, in: feedback)
            let feedbackFrame = feedback.exists && feedback.isHittable && !targetIsInFeedback
                ? feedback.frame : nil
            if let feedbackFrame, !usable(feedbackFrame) { continue }
            let bottom = min(lowerSystemBound, feedbackFrame?.minY ?? lowerSystemBound)
            guard bottom - top > 48 else { continue }
            let elementFrame = element.exists ? element.frame : nil
            if let elementFrame, !usable(elementFrame) { continue }
            if let elementFrame, element.isHittable && elementFrame.minY >= top
                && elementFrame.maxY <= bottom
            {
                return
            }
            let x = appFrame.midX
            let viewportHeight = bottom - top
            let upper = top + viewportHeight / 4
            let lower = top + viewportHeight * 3 / 4
            let maximumTravel = lower - upper
            let minimumTravel = min(60, maximumTravel)
            if let elementFrame, elementFrame.minY < top {
                let travel = min(max(top - elementFrame.minY + 12, minimumTravel), maximumTravel)
                drag(in: app, x: x, from: upper, to: upper + travel)
            } else if let elementFrame, elementFrame.maxY > bottom {
                let travel = min(max(elementFrame.maxY - bottom + 12, minimumTravel), maximumTravel)
                drag(in: app, x: x, from: lower, to: lower - travel)
            } else {
                drag(in: app, x: x, from: lower, to: upper)
            }
        }
        XCTFail("Could not reveal \(element.identifier) above the keyboard and tab bar")
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }

    private func contains(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        guard element.exists, usable(element.frame), container.exists else { return false }
        return container.descendants(matching: element.elementType).matching(NSPredicate(
            format: "identifier == %@ AND label == %@", element.identifier, element.label
        )).firstMatch.exists
    }

    private func drag(in app: XCUIApplication, x: CGFloat, from startY: CGFloat, to endY: CGFloat) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: x, dy: startY))
        let end = origin.withOffset(CGVector(dx: x, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func usable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty
            && frame.minX.isFinite && frame.minY.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite
    }

    private func resetCatalogFilters(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Catalog filters"].waitForExistence(timeout: 2))
        let reset = app.buttons["shopping.catalog.reset"].firstMatch
        reveal(reset, in: app)
        XCTAssertTrue(reset.waitForExistence(timeout: 2))
        reset.tap()
    }

    private func openOneTimeAdd(in app: XCUIApplication, groceryName: String) {
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add item"].waitForExistence(timeout: 2))
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
