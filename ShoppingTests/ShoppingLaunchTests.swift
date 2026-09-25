import XCTest

final class ShoppingLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsEmptyGroceriesAndConnectedTabs() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.buttons["shopping.addGrocery"].exists)
        XCTAssertTrue(app.tabBars.buttons["Catalog"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        attachScreenshot(named: "Empty Groceries", app: app)

        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].existsOrAppears(timeout: 2))
        XCTAssertFalse(app.buttons["Import CSV"].exists)
        XCTAssertFalse(app.buttons["shopping.catalog.import"].exists)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].existsOrAppears(timeout: 2))
        let version = app.descendants(matching: .any)["shopping.settings.version"]
        XCTAssertTrue(version.existsOrAppears(timeout: 2))
        XCTAssertTrue(version.label.contains("1.2.0"))
        XCTAssertNotNil(version.label.range(
            of: #"\([0-9a-f]{8}(?:-dirty)?\)"#, options: .regularExpression
        ))
    }

    func testCategorySuggestionIsVisibleInCatalogAndGroceryEditors() {
        let app = launchApp()

        app.tabBars.buttons["Catalog"].tap()
        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.category.recommendation"].existsOrAppears(timeout: 2))
        app.buttons["Cancel"].firstMatch.tap()

        app.tabBars.buttons["Groceries"].tap()
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].existsOrAppears(timeout: 2))
        app.buttons["shopping.grocery.addOneTime"].tap()
        XCTAssertTrue(app.navigationBars["Add item"].existsOrAppears(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.category.recommendation"].existsOrAppears(timeout: 2))
    }

    func testPopulatedCostcoNavigationAtAccessibilitySize() {
        let app = launchApp(fixture: "populated", accessibilitySize: true)
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        let storeMenu = app.buttons["shopping.store.menu"]
        XCTAssertTrue(storeMenu.existsOrAppears(timeout: 3))
        storeMenu.tap()
        let costco = app.buttons["Costco"]
        XCTAssertTrue(costco.existsOrAppears(timeout: 2))
        costco.tap()
        XCTAssertTrue(shoppingHeading("Produce", in: app).existsOrAppears(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.filters"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "In cart")).firstMatch.exists)
        let bakerySection = shoppingHeading("Bakery", in: app)
        for _ in 0..<8 where !bakerySection.exists || !bakerySection.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(bakerySection.exists)
        XCTAssertTrue(bakerySection.isHittable)
        XCTAssertTrue(storeRuleRow("Only buy here", in: app).exists)
        XCTAssertTrue(storeRuleRow("Can buy here", in: app).exists)
        attachScreenshot(named: "Populated Costco Accessibility Large", app: app)
    }

    func testStoreScopeUsesCategorySectionsAndRowIndicatorsInBothAppearances() {
        for appearance in ["light", "dark"] {
            let app = launchApp(fixture: "populated", appearance: appearance)
            XCTAssertFalse(shoppingHeading("Only buy here", in: app).exists)
            XCTAssertFalse(shoppingHeading("Can buy here", in: app).exists)
            XCTAssertFalse(app.staticTexts["Needs store"].exists)
            app.buttons["shopping.store.menu"].tap()
            app.buttons["Costco"].tap()
            XCTAssertTrue(shoppingHeading("Produce", in: app).existsOrAppears(timeout: 2))
            let pantry = shoppingHeading("Pantry", in: app)
            reveal(pantry, in: app)
            XCTAssertTrue(pantry.isHittable)
            XCTAssertFalse(shoppingHeading("Only buy here", in: app).exists)
            XCTAssertFalse(shoppingHeading("Can buy here", in: app).exists)
            XCTAssertTrue(storeRuleRow("Only buy here", in: app).exists)
            XCTAssertTrue(storeRuleRow("Can buy here", in: app).exists)
            XCTAssertFalse(app.staticTexts["Buy at any store"].exists)
            XCTAssertFalse(app.staticTexts["Only buy at Costco"].exists)
            XCTAssertFalse(app.buttons["Edit Chipotles in adobo"].exists)
            XCTAssertFalse(app.buttons["Edit Local honey"].exists)

            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "In cart")
            ).firstMatch.tap()
            XCTAssertTrue(app.navigationBars["In cart"].existsOrAppears(timeout: 2))
            XCTAssertTrue(shoppingHeading("Produce", in: app).existsOrAppears(timeout: 2))
            XCTAssertTrue(storeRuleRow("Only buy here", in: app).exists)
            XCTAssertFalse(shoppingHeading("Only buy here", in: app).exists)
            attachScreenshot(named: "Compact Costco \(appearance)", app: app)
            app.terminate()
        }
    }

    func testOneTimeAddSavesWithoutStoreSetupAndDoesNotPolluteCatalog() {
        let app = launchApp()
        openOneTimeAdd(in: app, groceryName: "Fresh basil")
        XCTAssertTrue(app.buttons["shopping.grocery.save"].isEnabled)
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(app.staticTexts["Fresh basil"].existsOrAppears(timeout: 3))

        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered items"].existsOrAppears(timeout: 2))
        XCTAssertFalse(app.staticTexts["Fresh basil"].exists)
    }

    func testStoreManagementStagesRenameAndDeletesUnreferencedStore() {
        let app = launchApp()
        openStoreManagement(in: app)

        app.buttons["shopping.stores.add"].tap()
        XCTAssertTrue(app.navigationBars["Add store"].existsOrAppears(timeout: 2))
        let createName = app.textFields["shopping.stores.name"]
        XCTAssertTrue(createName.existsOrAppears(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.existsOrAppears(timeout: 2))
        createName.typeText("Neighborhood Market")
        app.buttons["Save store"].tap()
        let neighborhoodMarket = storeManagementRow(named: "Neighborhood Market", in: app)
        XCTAssertTrue(neighborhoodMarket.existsOrAppears(timeout: 2))

        neighborhoodMarket.tap()
        XCTAssertTrue(app.navigationBars["Rename store"].existsOrAppears(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.stores.name"], with: "Canceled Market")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(neighborhoodMarket.existsOrAppears(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled Market"].exists)

        neighborhoodMarket.tap()
        XCTAssertTrue(app.navigationBars["Rename store"].existsOrAppears(timeout: 2))
        replaceText(in: app.textFields["shopping.stores.name"], with: "Local Market")
        app.buttons["Save store"].tap()
        let localMarket = storeManagementRow(named: "Local Market", in: app)
        XCTAssertTrue(localMarket.existsOrAppears(timeout: 2))
        XCTAssertFalse(neighborhoodMarket.exists)

        localMarket.swipeLeft()
        XCTAssertFalse(app.buttons["Edit"].exists)
        XCTAssertTrue(app.buttons["Archive"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
        app.buttons["Delete"].tap()
        let deleteStore = app.buttons["Delete store"]
        XCTAssertTrue(deleteStore.existsOrAppears(timeout: 2))
        deleteStore.tap()
        XCTAssertFalse(localMarket.waitForExistence(timeout: 2))
    }

    func testPeopleRemainVisibleAfterRelaunch() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingPeopleUITest-\(UUID().uuidString).sqlite")
        let app = launchApp(storeURL: storeURL)
        openPeopleManagement(in: app)
        app.buttons["shopping.people.add"].tap()
        XCTAssertTrue(app.navigationBars["Add person"].existsOrAppears(timeout: 2))
        let name = app.textFields["shopping.people.name"]
        XCTAssertTrue(name.existsOrAppears(timeout: 2))
        name.typeText("Taylor")
        app.buttons["Save person"].tap()
        XCTAssertTrue(app.buttons["Taylor"].existsOrAppears(timeout: 2))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        openPeopleManagement(in: app)
        XCTAssertTrue(app.buttons["Taylor"].existsOrAppears(timeout: 3))
    }

    func testStoreManagementArchivesReferencedStoreHidesItAndResetsSelectedStore() {
        let app = launchApp(fixture: "populated")
        app.buttons["shopping.store.menu"].tap()
        app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Costco", "shopping.store.menu")
        ).firstMatch.tap()
        XCTAssertTrue(app.buttons["shopping.store.clear"].existsOrAppears(timeout: 2))

        openStoreManagement(in: app)
        XCTAssertTrue(storeManagementRow(named: "Neighborhood Market (closed)", in: app).exists)
        let costco = storeManagementRow(named: "Costco", in: app)
        costco.swipeLeft()
        XCTAssertFalse(app.buttons["Edit"].exists)
        XCTAssertTrue(app.buttons["Archive"].exists)
        app.buttons["Archive"].tap()
        XCTAssertTrue(app.staticTexts["Archived"].existsOrAppears(timeout: 2))
        XCTAssertTrue(costco.exists)
        costco.tap()
        XCTAssertTrue(app.navigationBars["Rename store"].existsOrAppears(timeout: 2))
        app.buttons["Cancel"].tap()

        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.buttons["shopping.store.all"].existsOrAppears(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.store.all"].isSelected)
        XCTAssertFalse(app.buttons["shopping.store.clear"].exists)
        app.buttons["shopping.store.menu"].tap()
        XCTAssertFalse(app.buttons["Costco"].waitForExistence(timeout: 2))
    }

    func testCancelingInlineStoreAndParentAddCreatesNeitherStoreNorNeed() {
        let app = launchApp()
        openOneTimeAdd(in: app, groceryName: "Canceled grocery")
        revealInlineAddStore(in: app).tap()
        XCTAssertTrue(app.navigationBars["Add store"].existsOrAppears(timeout: 2))
        let storeName = app.textFields["shopping.tags.storeName"]
        XCTAssertTrue(app.keyboards.firstMatch.existsOrAppears(timeout: 2))
        storeName.typeText("Canceled store")
        app.buttons["shopping.tags.storeCancel"].tap()
        XCTAssertTrue(app.navigationBars["Add item"].existsOrAppears(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled store"].exists)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].existsOrAppears(timeout: 2))
        openStoreManagement(in: app)
        XCTAssertFalse(app.staticTexts["Canceled store"].exists)
    }

    func testSavingInlineStoreSelectsItButParentCancelCreatesNoNeed() {
        let app = launchApp()
        openOneTimeAdd(in: app, groceryName: "Canceled assigned grocery")
        revealInlineAddStore(in: app).tap()
        XCTAssertTrue(app.navigationBars["Add store"].existsOrAppears(timeout: 2))
        let storeName = app.textFields["shopping.tags.storeName"]
        XCTAssertTrue(app.keyboards.firstMatch.existsOrAppears(timeout: 2))
        storeName.typeText("Corner Shop")
        app.buttons["shopping.tags.storeSave"].tap()

        XCTAssertTrue(app.navigationBars["Add item"].existsOrAppears(timeout: 2))
        let selectedStore = app.buttons["Corner Shop"]
        XCTAssertTrue(selectedStore.existsOrAppears(timeout: 2))
        XCTAssertEqual(selectedStore.value as? String, "Selected")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].existsOrAppears(timeout: 2))

        openStoreManagement(in: app)
        XCTAssertTrue(storeManagementRow(named: "Corner Shop", in: app).existsOrAppears(timeout: 2))
    }

    func testCategoryAndUrgentFilterChipsNarrowThenBroadenTheExistingGroceries() {
        let app = launchApp(fixture: "populated")
        XCTAssertTrue(app.staticTexts["Granola"].existsOrAppears(timeout: 3))
        revealGrocery(named: "Chipotles in adobo", in: app)

        app.buttons["shopping.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].existsOrAppears(timeout: 2))
        setSwitch(named: "Urgent only", on: true, in: app)
        let pantry = app.buttons["Pantry"]
        XCTAssertTrue(pantry.existsOrAppears(timeout: 2))
        pantry.tap()
        dismissGroceryFilters(in: app)

        XCTAssertTrue(app.buttons["Remove Urgent filter"].existsOrAppears(timeout: 2))
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

    func testIncludedAndExcludedStoreChipsGiveExclusionPrecedence() {
        let app = launchApp(fixture: "populated")
        XCTAssertTrue(app.staticTexts["Granola"].existsOrAppears(timeout: 3))

        app.buttons["shopping.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].existsOrAppears(timeout: 2))
        setStoreFilter(named: "Costco", in: .include, on: true, app: app)
        setStoreFilter(named: "Costco", in: .exclude, on: true, app: app)
        dismissGroceryFilters(in: app)

        XCTAssertTrue(app.buttons["Remove Includes Costco filter"].existsOrAppears(timeout: 2))
        XCTAssertTrue(app.buttons["Remove Excludes Costco filter"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].existsOrAppears(timeout: 2))
        XCTAssertTrue(app.staticTexts["No matching groceries"].exists)

        app.buttons["Remove Excludes Costco filter"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Granola"].existsOrAppears(timeout: 2))
        XCTAssertTrue(app.buttons["Remove Includes Costco filter"].exists)
    }

    func testCatalogEditorCancelAndSavedAnyStoreItemDoNotCreateGroceries() {
        let app = launchApp()
        openCatalog(in: app)

        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.existsOrAppears(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Canceled catalog item")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Canceled catalog item"].waitForExistence(timeout: 2))

        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Reusable coffee")
        replaceText(in: app.textFields["shopping.catalog.notes"], with: "Whole bean")
        let addCategory = app.buttons["shopping.category.add"]
        reveal(addCategory, in: app)
        addCategory.tap()
        XCTAssertTrue(app.navigationBars["Add category"].existsOrAppears(timeout: 2))
        let categoryName = app.textFields["shopping.category.name"]
        XCTAssertTrue(categoryName.existsOrAppears(timeout: 2))
        categoryName.typeText("Coffee")
        app.buttons["shopping.category.save"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 2))
        let coffeeCategory = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.category.", "Coffee"
        )).firstMatch
        reveal(coffeeCategory, in: app)
        XCTAssertEqual(coffeeCategory.value as? String, "Selected")
        let anyStore = app.buttons["shopping.purchase.anyStore"]
        reveal(anyStore, in: app)
        XCTAssertTrue(anyStore.existsOrAppears(timeout: 2))
        let anyStoreControl = anyStore.switches.firstMatch
        (anyStoreControl.exists ? anyStoreControl : anyStore).tap()
        XCTAssertEqual(anyStore.value as? String, "Selected")
        let save = app.buttons["shopping.catalog.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let reusableCoffee = searchCatalog(for: "Reusable coffee", in: app)

        reveal(reusableCoffee, in: app)
        reusableCoffee.tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].existsOrAppears(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Canceled coffee edit")
        app.buttons["Cancel"].tap()
        reveal(reusableCoffee, in: app)
        XCTAssertFalse(app.staticTexts["Canceled coffee edit"].exists)

        reusableCoffee.tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].existsOrAppears(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Saved coffee edit")
        app.buttons["shopping.catalog.save"].tap()
        let savedCoffee = searchCatalog(for: "Saved coffee edit", in: app)

        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].existsOrAppears(timeout: 2))
        XCTAssertFalse(app.staticTexts["Saved coffee edit"].exists)

        openCatalog(in: app)
        XCTAssertTrue(savedCoffee.existsOrAppears(timeout: 2))
        savedCoffee.swipeLeft()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.swipeArchive."
        )).firstMatch.existsOrAppears(timeout: 2))
        let delete = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.swipeDelete."
        )).firstMatch
        XCTAssertTrue(delete.exists)
        delete.tap()
        let deleteItem = app.buttons["Delete item"]
        XCTAssertTrue(deleteItem.existsOrAppears(timeout: 2))
        deleteItem.tap()
        XCTAssertFalse(app.staticTexts["Saved coffee edit"].waitForExistence(timeout: 2))
    }

    func testCatalogUsesCategorySectionsWithoutAnAlternateGroupingMode() {
        let app = launchApp(fixture: "populated")
        openCatalog(in: app)

        XCTAssertFalse(app.buttons["shopping.catalog.grouping"].exists)
        for category in ["Produce", "Pantry", "Bakery"] {
            let heading = app.staticTexts[category]
            reveal(heading, in: app)
            XCTAssertTrue(heading.exists, "Expected category section \(category)")
        }
        attachScreenshot(named: "Catalog grouped by category", app: app)

        let chipotles = app.staticTexts["Chipotles in adobo"]
        reveal(chipotles, in: app)
        let groupedCategoryRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.item."
        )).containing(.staticText, identifier: "Chipotles in adobo").firstMatch
        XCTAssertTrue(groupedCategoryRow.label.contains("Publix"))
        XCTAssertFalse(groupedCategoryRow.label.contains("Pantry"))
        let archivedStoreRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.item."
        )).containing(.staticText, identifier: "Local honey").firstMatch
        reveal(archivedStoreRow, in: app)
        XCTAssertTrue(archivedStoreRow.label.contains("Neighborhood Market (closed) (archived)"))
        let multiStoreRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.item."
        )).containing(.staticText, identifier: "Dinner rolls").firstMatch
        reveal(multiStoreRow, in: app)
        XCTAssertTrue(multiStoreRow.label.contains("Costco, Walmart"))
        XCTAssertFalse(multiStoreRow.label.contains("Also:"))
        let visibleChipotlesRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.catalog.item.", "Chipotles in adobo"
        )).firstMatch
        reveal(visibleChipotlesRow, in: app)
        visibleChipotlesRow.swipeLeft()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.removeFromList."
        )).firstMatch.existsOrAppears(timeout: 2))
        XCTAssertFalse(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.addToCart."
        )).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.swipeArchive."
        )).firstMatch.existsOrAppears(timeout: 2))
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.swipeDelete."
        )).firstMatch.exists)
        attachScreenshot(named: "Catalog top row swipe", app: app)
        visibleChipotlesRow.swipeRight()
    }

    func testCatalogCategoryFiltersAllowMultipleSelections() {
        let app = launchApp(fixture: "populated")
        openCatalog(in: app)

        app.buttons["shopping.catalog.filters"].tap()
        XCTAssertTrue(app.navigationBars["Catalog filters"].existsOrAppears(timeout: 2))
        app.buttons["Produce"].tap()
        app.buttons["Pantry"].tap()
        app.buttons["Done"].tap()

        XCTAssertTrue(app.staticTexts["Bananas"].existsOrAppears(timeout: 2))
        reveal(app.staticTexts["Granola"], in: app)
        XCTAssertTrue(app.staticTexts["Granola"].exists)
        XCTAssertFalse(app.staticTexts["Dinner rolls"].exists)
    }

    func testCatalogArchiveFilterAndRestorePreservesActiveGrocery() {
        let app = launchApp(fixture: "populated")
        openCatalog(in: app)
        XCTAssertTrue(app.staticTexts["Granola"].existsOrAppears(timeout: 3))
        let catalogRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.catalog.item."))
            .containing(.staticText, identifier: "Granola").firstMatch
        reveal(catalogRow, in: app)
        catalogRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].existsOrAppears(timeout: 2))
        reveal(app.buttons["shopping.catalog.archive"], in: app)
        app.buttons["shopping.catalog.archive"].tap()
        tapArchiveStateConfirmation(in: "Archive this catalog item?", app: app)
        XCTAssertFalse(app.staticTexts["Granola"].waitForExistence(timeout: 2))

        app.buttons["shopping.catalog.filters"].tap()
        enableArchivedItems(in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].existsOrAppears(timeout: 2))

        app.staticTexts["Granola"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].existsOrAppears(timeout: 2))
        reveal(app.buttons["shopping.catalog.archive"], in: app)
        app.buttons["shopping.catalog.archive"].tap()
        XCTAssertFalse(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 2))

        app.buttons["shopping.catalog.filters"].tap()
        resetCatalogFilters(in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].existsOrAppears(timeout: 2))

        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].existsOrAppears(timeout: 2))
    }

    func testDirtyArchivedCatalogRestoreConfirmationCancelKeepsEditorDraft() {
        let app = launchApp(fixture: "archivedCatalogItem")
        openCatalog(in: app)
        app.buttons["shopping.catalog.filters"].tap()
        enableArchivedItems(in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Granola"].existsOrAppears(timeout: 2))
        app.staticTexts["Granola"].tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].existsOrAppears(timeout: 2))
        replaceText(in: app.textFields["shopping.catalog.name"], with: "Draft granola")
        replaceText(in: app.textFields["shopping.catalog.notes"], with: "Draft note")
        let draftName = app.textFields["shopping.catalog.name"].value as? String
        let draftNotes = app.textFields["shopping.catalog.notes"].value as? String
        XCTAssertNotEqual(draftName, "Granola")
        XCTAssertFalse(draftNotes?.isEmpty ?? true)
        reveal(app.buttons["shopping.catalog.archive"], in: app)
        app.buttons["shopping.catalog.archive"].tap()
        XCTAssertTrue(app.staticTexts["Restore this catalog item?"].existsOrAppears(timeout: 2))

        let restoreAlert = app.alerts["Restore this catalog item?"]
        XCTAssertTrue(restoreAlert.existsOrAppears(timeout: 2))
        let keepEditing = restoreAlert.buttons["Keep editing"].firstMatch
        XCTAssertTrue(keepEditing.existsOrAppears(timeout: 2))
        keepEditing.tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].existsOrAppears(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.catalog.name"].value as? String, draftName)
        XCTAssertEqual(app.textFields["shopping.catalog.notes"].value as? String, draftNotes)
    }

    func testCatalogFilterResetAtAccessibilitySizeDoesNotChangeGroceries() {
        let app = launchApp(fixture: "populated", accessibilitySize: true)
        openCatalog(in: app)
        let catalogGranola = app.staticTexts["Granola"]
        reveal(catalogGranola, in: app)
        XCTAssertTrue(catalogGranola.existsOrAppears(timeout: 3))
        let filters = app.buttons["shopping.catalog.filters"]
        for _ in 0..<8 where !filters.exists || !filters.isHittable {
            app.collectionViews["shopping.catalog.list"].swipeDown()
        }
        XCTAssertTrue(filters.existsOrAppears(timeout: 3))
        XCTAssertTrue(filters.isHittable)
        filters.tap()
        enableArchivedItems(in: app)
        resetCatalogFilters(in: app)
        app.buttons["Done"].tap()
        reveal(catalogGranola, in: app)
        XCTAssertTrue(catalogGranola.existsOrAppears(timeout: 2))
        attachScreenshot(named: "Populated Catalog Accessibility Large", app: app)

        app.tabBars.buttons["Groceries"].tap()
        let groceryGranola = app.staticTexts["Granola"]
        reveal(groceryGranola, in: app)
        XCTAssertTrue(groceryGranola.existsOrAppears(timeout: 2))
        let bananas = app.buttons["Edit Bananas"]
        for _ in 0..<6 where !bananas.exists { app.swipeUp() }
        XCTAssertTrue(bananas.existsOrAppears(timeout: 2))
    }

    private func revealInlineAddStore(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["shopping.tags.addStore"]
        if app.keyboards.firstMatch.exists {
            app.buttons["shopping.grocery.keyboardDone"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        }
        for _ in 0..<8 {
            let top = app.navigationBars["Add item"].frame.maxY
            let bottom = app.frame.maxY - 40
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

    private func launchApp(
        fixture: String? = nil,
        accessibilitySize: Bool = false,
        appearance: String? = nil,
        storeURL: URL? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = (
            storeURL ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ShoppingUITest-\(UUID().uuidString).sqlite")
        ).path
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
        XCTAssertTrue(app.navigationBars["Settings"].existsOrAppears(timeout: 2))
        app.buttons["Stores"].tap()
        XCTAssertTrue(app.navigationBars["Stores"].existsOrAppears(timeout: 2))
    }

    private func openPeopleManagement(in app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].existsOrAppears(timeout: 2))
        app.buttons["People"].tap()
        XCTAssertTrue(app.navigationBars["People"].existsOrAppears(timeout: 2))
    }

    private func storeManagementRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    private func openCatalog(in app: XCUIApplication) {
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].existsOrAppears(timeout: 2))
    }

    private enum StoreFilterSection {
        case include
        case exclude

        var header: String {
            switch self {
            case .include: "Include stores"
            case .exclude: "Exclude stores"
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
        XCTAssertTrue(toggle.existsOrAppears(timeout: 2))
        if (toggle.value as? String == "1") != on {
            let control = toggle.switches.firstMatch
            (control.exists ? control : toggle).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    private func setStoreFilter(
        named name: String,
        in section: StoreFilterSection,
        on: Bool,
        app: XCUIApplication
    ) {
        XCTAssertTrue(app.navigationBars["Filters"].exists)
        let header = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@", section.header)
        ).firstMatch
        reveal(header, in: app)
        XCTAssertTrue(header.exists)
        let choices = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", section.identifierPrefix, name
        ))
        let pill = choices.firstMatch
        reveal(pill, in: app)
        XCTAssertEqual(choices.count, 1)
        XCTAssertTrue(pill.isHittable)
        if (pill.value as? String == "Selected") != on { pill.tap() }
        XCTAssertEqual(pill.value as? String, on ? "Selected" : "Not selected")
    }

    private func shoppingHeading(_ title: String, in app: XCUIApplication) -> XCUIElement {
        // iOS 18 uppercases native section headers; iOS 26 keeps sentence case.
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch
    }

    private func storeRuleRow(_ rule: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value CONTAINS %@",
            "shopping.grocery.row.", rule
        )).firstMatch
    }

    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval = 2) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", label),
                object: element
            )],
            timeout: timeout
        ) == .completed
    }

    private func revealGrocery(named name: String, in app: XCUIApplication, towardTop: Bool = false) {
        let grocery = app.buttons["Edit \(name)"]
        for _ in 0..<6 where !grocery.exists {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(grocery.existsOrAppears(timeout: 2), "Expected grocery \(name) to be visible")
    }

    private func assertNoGrocery(named name: String, in app: XCUIApplication) {
        let grocery = app.buttons["Edit \(name)"]
        for _ in 0..<6 where !grocery.exists {
            app.swipeUp()
        }
        XCTAssertFalse(grocery.exists, "Did not expect grocery \(name) after filtering")
    }

    private func enableArchivedItems(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Catalog filters"].existsOrAppears(timeout: 2))
        let archived = app.buttons["shopping.catalog.archived"]
        reveal(archived, in: app)
        archived.tap()
        XCTAssertTrue(archived.isSelected)
    }

    private func tapArchiveStateConfirmation(in title: String, app: XCUIApplication) {
        let confirmation = app.alerts[title]
        XCTAssertTrue(confirmation.existsOrAppears(timeout: 2))
        let action = confirmation.buttons["shopping.catalog.confirmArchiveState"].firstMatch
        XCTAssertTrue(action.existsOrAppears(timeout: 2))
        action.tap()
        XCTAssertFalse(confirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["Catalog"].existsOrAppears(timeout: 2))
        XCTAssertFalse(app.navigationBars["Edit catalog item"].exists)
    }

    private func catalogItem(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.catalog.item.", name
        )).firstMatch
    }

    private func searchCatalog(for name: String, in app: XCUIApplication) -> XCUIElement {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.existsOrAppears(timeout: 2))
        replaceText(in: search, with: name)
        search.typeKey(.return, modifierFlags: [])
        let cancelSearch = app.buttons["Cancel"]
        if cancelSearch.waitForExistence(timeout: 1) {
            cancelSearch.tap()
        } else {
            let closeKeyboard = app.buttons["Close"]
            XCTAssertTrue(closeKeyboard.existsOrAppears(timeout: 1))
            closeKeyboard.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        let item = catalogItem(named: name, in: app)
        XCTAssertTrue(item.existsOrAppears(timeout: 3))
        XCTAssertTrue(item.isHittable)
        return item
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
        XCTAssertTrue(element.existsOrAppears(timeout: 2))
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
        XCTAssertTrue(app.navigationBars["Catalog filters"].existsOrAppears(timeout: 2))
        let reset = app.buttons["shopping.catalog.reset"].firstMatch
        reveal(reset, in: app)
        XCTAssertTrue(reset.existsOrAppears(timeout: 2))
        reset.tap()
    }

    private func openOneTimeAdd(in app: XCUIApplication, groceryName: String) {
        XCTAssertTrue(app.buttons["shopping.addGrocery"].existsOrAppears(timeout: 5))
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].existsOrAppears(timeout: 2))
        let addOneTime = app.buttons["shopping.grocery.addOneTime"]
        reveal(addOneTime, in: app)
        XCTAssertTrue(addOneTime.existsOrAppears(timeout: 2))
        addOneTime.tap()
        XCTAssertTrue(app.navigationBars["Add item"].existsOrAppears(timeout: 2))
        setSwitch(named: "shopping.grocery.remembered", on: false, in: app)
        let name = app.textFields["shopping.grocery.name"]
        name.tap()
        name.typeText(groceryName)
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        if let remainingText = field.value as? String, !remainingText.isEmpty {
            // Keep the fallback keystrokes in one automation event. A separate
            // typeKey call per character repeatedly synchronizes with the app.
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: remainingText.count))
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
