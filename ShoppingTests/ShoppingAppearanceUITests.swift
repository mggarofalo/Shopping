import XCTest

final class ShoppingAppearanceUITests: XCTestCase {
    func testGroceryAndCatalogShareRowHeightAndFilterControlDimensions() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedRows-\(UUID().uuidString).sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let grocery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.grocery.row.", "Edit Chipotles in adobo")).firstMatch
        for _ in 0..<6 where !grocery.isHittable { app.swipeUp() }
        XCTAssertTrue(grocery.existsOrAppears(timeout: 3))
        let groceryCell = app.collectionViews.cells.containing(.button, identifier: grocery.identifier).firstMatch
        let groceryHeight = groceryCell.frame.height
        XCTAssertGreaterThanOrEqual(grocery.frame.height, 44,
                                    "The item edit target must include the blank space beside short titles")
        XCTAssertTrue((grocery.value as? String ?? "").contains("Publix"))
        attach("Normalized grocery rows", app)
        for _ in 0..<6 where !app.buttons["shopping.filters"].isHittable { app.swipeDown() }
        let filtersSize = app.buttons["shopping.filters"].frame.size
        let storeSize = app.buttons["shopping.store.menu"].frame.size
        let addSize = app.buttons["shopping.addGrocery"].frame.size
        app.tabBars.buttons["Catalog"].tap()
        let catalog = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.catalog.item.", "Chipotles in adobo")).firstMatch
        for _ in 0..<6 where !catalog.isHittable { app.swipeUp() }
        XCTAssertTrue(catalog.existsOrAppears(timeout: 3))
        let catalogCell = app.collectionViews.cells.containing(.button, identifier: catalog.identifier).firstMatch
        XCTAssertEqual(catalogCell.frame.height, groceryHeight, accuracy: 1)
        attach("Normalized catalog rows", app)
        for _ in 0..<6 where !app.buttons["shopping.catalog.filters"].isHittable { app.swipeDown() }
        XCTAssertEqual(app.buttons["shopping.catalog.filters"].frame.height, filtersSize.height, accuracy: 1)
        XCTAssertEqual(app.buttons["shopping.catalog.filters"].frame.width, filtersSize.width, accuracy: 1)
        XCTAssertEqual(app.buttons["shopping.catalog.store.menu"].frame.height, storeSize.height, accuracy: 1)
        XCTAssertEqual(app.buttons["shopping.catalog.store.menu"].frame.width, storeSize.width, accuracy: 1)
        XCTAssertEqual(app.buttons["shopping.catalog.add"].frame.height, addSize.height, accuracy: 1)
        XCTAssertEqual(app.buttons["shopping.catalog.add"].frame.width, addSize.width, accuracy: 1)
    }

    func testPrimaryScreensEditorsAndFiltersInBothAppearances() {
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            for appearance in ["light", "dark"] {
                let app = XCUIApplication()
                app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] =
                    FileManager.default.temporaryDirectory.appendingPathComponent(
                        "AppearanceReview-\(UUID().uuidString).sqlite"
                    ).path
                app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
                app.launchArguments = [
                    "-UIPreferredContentSizeCategoryName", size,
                    "-shopping.appearance", appearance
                ]
                app.launch()
                XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
                attach("Groceries \(appearance) \(size)", app)
                app.buttons["shopping.filters"].tap()
                XCTAssertTrue(app.navigationBars["Filters"].existsOrAppears(timeout: 3))
                attach("Grocery filters \(appearance) \(size)", app)
                app.buttons["Done"].tap()
                app.buttons["shopping.addGrocery"].tap()
                XCTAssertTrue(app.navigationBars["Add to Groceries"].existsOrAppears(timeout: 3))
                let addOneTime = app.buttons["shopping.grocery.addOneTime"]
                for _ in 0..<8 {
                    if addOneTime.exists,
                       addOneTime.isHittable,
                       addOneTime.frame.maxY <= app.frame.maxY - 24 {
                        break
                    }
                    app.swipeUp()
                }
                XCTAssertTrue(addOneTime.existsOrAppears(timeout: 3))
                XCTAssertLessThanOrEqual(addOneTime.frame.maxY, app.frame.maxY - 24)
                XCTAssertTrue(addOneTime.isHittable)
                addOneTime.tap()
                XCTAssertTrue(app.navigationBars["Add item"].existsOrAppears(timeout: 3))
                attach("Grocery editor \(appearance) \(size)", app)
                app.buttons["shopping.grocery.cancel"].tap()
                app.tabBars.buttons["Catalog"].tap()
                app.buttons["shopping.catalog.filters"].tap()
                XCTAssertTrue(app.navigationBars["Catalog filters"].existsOrAppears(timeout: 3))
                attach("Catalog filters \(appearance) \(size)", app)
                app.buttons["Done"].tap()
                app.buttons["shopping.catalog.add"].tap()
                XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 3))
                attach("Catalog editor \(appearance) \(size)", app)
                app.buttons["Cancel"].tap()
                openSettings(app)
                attach("Settings \(appearance) \(size)", app)
                app.terminate()
            }
        }
    }

    func testCatalogHasTopInsetInLightAndDarkAtStandardAndLargeText() {
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            for appearance in ["light", "dark"] {
                let app = XCUIApplication()
                app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] =
                    FileManager.default.temporaryDirectory.appendingPathComponent(
                        "CatalogAppearance-\(UUID().uuidString).sqlite"
                    ).path
                app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
                app.launchArguments = [
                    "-UIPreferredContentSizeCategoryName", size,
                    "-shopping.appearance", appearance
                ]
                app.launch()
                XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
                app.tabBars.buttons["Catalog"].tap()
                let list = app.collectionViews["shopping.catalog.list"]
                XCTAssertTrue(list.existsOrAppears(timeout: 3))
                let firstItem = app.buttons.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@", "shopping.catalog.item."
                )).firstMatch
                XCTAssertTrue(firstItem.existsOrAppears(timeout: 3))
                let firstCell = list.cells.containing(.button, identifier: firstItem.identifier).firstMatch
                XCTAssertTrue(firstCell.existsOrAppears(timeout: 3))
                let filters = app.buttons["shopping.catalog.filters"]
                XCTAssertGreaterThanOrEqual(firstCell.frame.minY - filters.frame.maxY, 12)
                XCTAssertTrue(firstCell.isHittable)
                XCTAssertGreaterThanOrEqual(firstCell.frame.height, 44)
                attach("Catalog \(appearance) \(size)", app)
                if size.contains("Accessibility") {
                    list.swipeUp()
                    XCTAssertTrue(!firstCell.exists || firstCell.frame.minY < list.frame.midY)
                    attach("Scrolled catalog \(appearance) \(size)", app)
                }
                app.terminate()
            }
        }
    }

    func testCompactGroceryAndPersonalCartTablesAtStandardAndLargeText() {
        for (size, appearance) in [
            ("UICTContentSizeCategoryL", "light"),
            ("UICTContentSizeCategoryAccessibilityXXXL", "dark")
        ] {
            let app = XCUIApplication()
            app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
                .appendingPathComponent("CompactTables-\(UUID().uuidString).sqlite").path
            app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
            app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1"
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size, "-shopping.appearance", appearance]
            app.launch()
            XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
            let grocery = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@", "shopping.grocery.row.", "Edit Bananas"
            )).firstMatch
            for _ in 0..<6 where !grocery.isHittable { app.swipeUp() }
            XCTAssertTrue(grocery.existsOrAppears(timeout: 3))
            XCTAssertTrue(grocery.isHittable)
            XCTAssertTrue(app.staticTexts["Produce"].exists)
            let groceryCell = app.collectionViews.cells.containing(.button, identifier: grocery.identifier).firstMatch
            XCTAssertGreaterThanOrEqual(groceryCell.frame.height, 44)
            let bareRowHeight = groceryCell.frame.height
            let needID = grocery.identifier.replacingOccurrences(of: "shopping.grocery.row.", with: "")
            let quantity = app.buttons["shopping.checklist.quantity.edit.\(needID)"]
            XCTAssertTrue(quantity.isHittable)
            XCTAssertEqual(quantity.value as? String, "6")
            XCTAssertGreaterThanOrEqual(quantity.frame.width, 44)
            XCTAssertGreaterThanOrEqual(quantity.frame.height, 44)
            XCTAssertLessThanOrEqual(quantity.frame.maxX, groceryCell.frame.maxX)
            if size == "UICTContentSizeCategoryL" {
                XCTAssertEqual(groceryCell.frame.height, 56, accuracy: 1,
                               "A simple quantity must not append another row of controls")
            }
            let richRow = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@", "shopping.grocery.row.", "Edit Granola"
            )).firstMatch
            for _ in 0..<6 where !richRow.isHittable { app.swipeUp() }
            XCTAssertTrue(richRow.existsOrAppears(timeout: 3))
            XCTAssertTrue(richRow.isHittable)
            let richCell = app.collectionViews.cells.containing(.button, identifier: richRow.identifier).firstMatch
            XCTAssertGreaterThanOrEqual(richCell.frame.height, 44)
            let titleText = richRow.staticTexts["Granola"]
            XCTAssertTrue(titleText.exists)
            XCTAssertGreaterThanOrEqual(titleText.frame.minY, richCell.frame.minY)
            XCTAssertLessThanOrEqual(titleText.frame.maxY, richCell.frame.maxY)
            let topPadding = titleText.frame.minY - richCell.frame.minY
            XCTAssertGreaterThanOrEqual(topPadding, 6)
            if size == "UICTContentSizeCategoryL" {
                let notesText = richRow.staticTexts["Low sugar"]
                XCTAssertTrue(notesText.exists)
                let bottomPadding = richCell.frame.maxY - notesText.frame.maxY
                XCTAssertGreaterThanOrEqual(bottomPadding, 6)
                XCTAssertEqual(topPadding, bottomPadding, accuracy: 3,
                               "Multiline content needs consistent top and bottom padding")
            } else {
                // AX has a full-width name target and a separate metadata/quantity line.
                // Its metadata is announced once in the name's value; inspect the attached
                // pixels for note padding and retain the complete content-sized cell bound.
                XCTAssertGreaterThan(richCell.frame.maxY, titleText.frame.maxY + 6)
            }
            if size == "UICTContentSizeCategoryL" {
                XCTAssertLessThan(richCell.frame.height, bareRowHeight * 3,
                                  "Short notes and one assignment must not reserve empty vertical space")
            }
            XCTAssertTrue((richRow.value as? String ?? "").contains("For Michael"))
            XCTAssertTrue((richRow.value as? String ?? "").contains("Low sugar"))
            attach("Content-sized groceries \(appearance) \(size)", app)
            for _ in 0..<6 where !grocery.isHittable { app.swipeDown() }
            XCTAssertTrue(grocery.isHittable)
            attach("Compact groceries \(appearance) \(size)", app)
            grocery.swipeLeft()
            let addToCart = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "shopping.checklist.cart."
            )).firstMatch
            XCTAssertTrue(addToCart.existsOrAppears(timeout: 3))
            addToCart.tap()
            let viewCart = app.buttons["In cart (1)"]
            for _ in 0..<6 where !viewCart.isHittable { app.swipeDown() }
            XCTAssertTrue(viewCart.existsOrAppears(timeout: 3))
            XCTAssertTrue(viewCart.isHittable)
            viewCart.tap()
            XCTAssertTrue(app.navigationBars["My cart"].existsOrAppears(timeout: 3))
            let cartRow = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "shopping.personalCart.item.", "Bananas"
            )).firstMatch
            XCTAssertTrue(cartRow.existsOrAppears(timeout: 3))
            XCTAssertTrue(cartRow.isHittable)
            XCTAssertGreaterThanOrEqual(cartRow.frame.height, 44)
            XCTAssertTrue(app.staticTexts["Produce"].exists)
            XCTAssertTrue(app.staticTexts["Bananas moved to In cart."].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Check out"].isHittable)
            attach("Compact personal cart \(appearance) \(size)", app)
            app.terminate()
        }
    }

    func testCatalogColumnsPreserveLongTextAndCompleteStoreAccessibility() {
        let name = "Organic family-size breakfast cereal with a deliberately long complete title"
        for (size, appearance) in [("UICTContentSizeCategoryL", "light"),
                                   ("UICTContentSizeCategoryAccessibilityXXXL", "dark")] {
            let app = XCUIApplication()
            app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
                .appendingPathComponent("CatalogColumns-\(UUID().uuidString).sqlite").path
            app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "catalogColumns"
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size, "-shopping.appearance", appearance]
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Catalog"].existsOrAppears(timeout: 5))
            app.tabBars.buttons["Catalog"].tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.existsOrAppears(timeout: 3))
            search.tap()
            search.typeText("Organic family-size\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "shopping.catalog.item.", name)).firstMatch
            XCTAssertTrue(row.existsOrAppears(timeout: 3))
            XCTAssertTrue(row.isHittable)
            XCTAssertTrue(row.label.contains("Costco, Neighborhood independent grocery market, Publix"))
            XCTAssertTrue(row.label.contains("Third supporting line"))
            let title = row.staticTexts[name]
            let notes = row.staticTexts["First supporting line\nSecond supporting line with more detail\nThird supporting line"]
            XCTAssertTrue(title.exists)
            XCTAssertTrue(notes.exists)
            XCTAssertLessThan(title.frame.maxY, notes.frame.minY + 1)
            XCTAssertGreaterThan(title.frame.height, size.contains("Accessibility") ? 100 : 35,
                                 "The complete long title must wrap instead of truncating to one line")
            XCTAssertGreaterThan(notes.frame.height, 35)
            let cell = app.collectionViews.cells.containing(.button, identifier: row.identifier).firstMatch
            XCTAssertGreaterThanOrEqual(title.frame.minY, cell.frame.minY)
            XCTAssertLessThanOrEqual(notes.frame.maxY, cell.frame.maxY)
            XCTAssertLessThanOrEqual(title.frame.width, row.frame.width * 0.7)
            XCTAssertLessThanOrEqual(notes.frame.width, row.frame.width * 0.7)
            attach("Catalog2to1 \(appearance) \(size)", app)
            if size.contains("Accessibility") {
                for _ in 0..<8 where notes.frame.maxY > app.frame.maxY - 100 { app.swipeUp() }
                XCTAssertTrue(notes.isHittable)
                XCTAssertLessThanOrEqual(notes.frame.maxY, app.frame.maxY - 100,
                                         "The end of an expanded row must remain reachable by scrolling")
                attach("Catalog long title scrolled to notes \(size)", app)
            }
            row.tap()
            XCTAssertTrue(app.navigationBars["Edit catalog item"].existsOrAppears(timeout: 3))
            XCTAssertEqual(app.textFields["shopping.catalog.name"].value as? String, name)
            app.terminate()
        }
    }

    func testManagementRowsKeepSharedSpacingWhenSelecting() {
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
                .appendingPathComponent("ManagementRows-\(UUID().uuidString).sqlite").path
            app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
            app.launch()
            XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
            openSettings(app)
            var standardHeight: CGFloat?
            for (screen, name, prefix) in [("Stores", "Costco", "stores"),
                                           ("Categories", "Produce", "categories"),
                                           ("People", "Michael", "people")] {
                app.buttons[screen].tap()
                let select = app.buttons["shopping.\(prefix).select"]
                XCTAssertTrue(select.existsOrAppears(timeout: 3))
                let cell = app.collectionViews.cells.containing(.any, identifier: name).firstMatch
                XCTAssertTrue(cell.existsOrAppears(timeout: 3))
                XCTAssertTrue(cell.isHittable)
                let height = cell.frame.height
                XCTAssertGreaterThanOrEqual(height, 56)
                if size == "UICTContentSizeCategoryL" {
                    if let standardHeight { XCTAssertEqual(height, standardHeight, accuracy: 1) }
                    standardHeight = height
                }
                attach("\(screen) rows \(size)", app)
                if screen == "Stores", size.contains("Accessibility") {
                    let archived = app.collectionViews.cells.containing(NSPredicate(
                        format: "label BEGINSWITH %@", "Neighborhood Market (closed)"
                    )).firstMatch
                    for _ in 0..<8 where !archived.isHittable || archived.frame.maxY > app.frame.maxY - 100 {
                        app.swipeUp()
                    }
                    XCTAssertTrue(archived.existsOrAppears(timeout: 3))
                    XCTAssertTrue(archived.isHittable)
                    XCTAssertLessThanOrEqual(archived.frame.maxY, app.frame.maxY - 100)
                    XCTAssertGreaterThan(archived.frame.height, height)
                    attach("Archived store name \(size)", app)
                    for _ in 0..<8 where !cell.isHittable { app.swipeDown() }
                    XCTAssertTrue(cell.isHittable)
                }
                select.tap()
                XCTAssertTrue(app.buttons["shopping.\(prefix).done"].existsOrAppears(timeout: 3))
                let selectedCell = app.collectionViews.cells.containing(.any, identifier: name).firstMatch
                XCTAssertTrue(selectedCell.existsOrAppears(timeout: 3))
                XCTAssertEqual(selectedCell.frame.height, height, accuracy: 1,
                               "Entering selection must not change row padding")
                selectedCell.tap()
                XCTAssertTrue(app.buttons["shopping.\(prefix).batchDelete"].isHittable)
                XCTAssertTrue(app.buttons["shopping.\(prefix).batchDelete"].isEnabled)
                app.buttons["shopping.\(prefix).done"].tap()
                app.navigationBars[screen].buttons.firstMatch.tap()
                XCTAssertTrue(app.navigationBars["Settings"].existsOrAppears(timeout: 3))
            }
            app.terminate()
        }
    }

    func testAppearanceChoicePersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] =
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "Appearance-\(UUID().uuidString).sqlite"
            ).path
        defer { select("System", in: app) }
        app.launch()
        app.createFirstHomeForWorkflow()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        openSettings(app)
        let scheme = app.segmentedControls["shopping.appearance"]
        XCTAssertTrue(scheme.existsOrAppears(timeout: 3))
        scheme.buttons["Light"].tap()
        attach("Light appearance", app)
        scheme.buttons["Dark"].tap()
        XCTAssertTrue(scheme.buttons["Dark"].isSelected)
        attach("Dark appearance", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        openSettings(app)
        XCTAssertTrue(app.segmentedControls["shopping.appearance"].buttons["Dark"].isSelected)
    }

    private func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].existsOrAppears(timeout: 3))
    }

    private func select(_ appearance: String, in app: XCUIApplication) {
        if app.state == .notRunning { app.launch() }
        openSettings(app)
        app.segmentedControls["shopping.appearance"].buttons[appearance].tap()
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
