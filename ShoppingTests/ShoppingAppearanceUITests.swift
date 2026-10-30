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
            if size.contains("Accessibility") {
                // Accessibility sizes stack the right-aligned stores below the full-width text.
                XCTAssertGreaterThan(title.frame.width, row.frame.width * 0.7)
            } else {
                XCTAssertLessThanOrEqual(title.frame.width, row.frame.width * 0.7)
                XCTAssertLessThanOrEqual(notes.frame.width, row.frame.width * 0.7)
            }
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

    func testGroceryStoreNamesTrailLikeCatalogAndRowsSizeToContent() {
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
                .appendingPathComponent("TrailingStores-\(UUID().uuidString).sqlite").path
            app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
            app.launch()
            XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
            let granola = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                "shopping.grocery.row.", "Edit Granola")).firstMatch
            for _ in 0..<6 where !granola.isHittable { app.swipeUp() }
            XCTAssertTrue(granola.existsOrAppears(timeout: 3))
            let cell = app.collectionViews.cells.containing(.button, identifier: granola.identifier).firstMatch
            let title = granola.staticTexts["Granola"]
            let store = granola.staticTexts["Costco"]
            XCTAssertTrue(title.exists)
            XCTAssertTrue(store.exists)
            XCTAssertEqual(cell.frame.maxX - store.frame.maxX, title.frame.minX - cell.frame.minX, accuracy: 1,
                           "Store names are right-aligned at the row's trailing inset")
            if size == "UICTContentSizeCategoryL" {
                XCTAssertGreaterThanOrEqual(store.frame.minX, title.frame.maxX, "Store names trail the name")
                XCTAssertLessThan(store.frame.minY, title.frame.maxY, "Store names share the name's first line")
            } else {
                XCTAssertGreaterThanOrEqual(store.frame.minY, title.frame.maxY - 1,
                                            "Accessibility sizes give the name the full width")
            }
            XCTAssertGreaterThanOrEqual(title.frame.minY - cell.frame.minY, 12,
                                        "Text must stay clear of the rounded row corners")
            attach("Trailing grocery stores \(size)", app)
            guard size == "UICTContentSizeCategoryL" else {
                app.terminate()
                continue
            }
            let notes = granola.staticTexts["Low sugar"]
            XCTAssertTrue(notes.exists)
            XCTAssertGreaterThanOrEqual(notes.frame.minY, title.frame.maxY - 1, "Notes stay under the name")
            XCTAssertLessThan(notes.frame.maxX, store.frame.minX)
            XCTAssertGreaterThanOrEqual(cell.frame.maxY - notes.frame.maxY, 12)
            let chipotles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                "shopping.grocery.row.", "Edit Chipotles in adobo")).firstMatch
            XCTAssertTrue(chipotles.existsOrAppears(timeout: 3))
            let chipotlesCell = app.collectionViews.cells.containing(.button, identifier: chipotles.identifier).firstMatch
            XCTAssertGreaterThan(cell.frame.height, chipotlesCell.frame.height,
                                 "A row with notes grows instead of sharing the single-line height")
            let groceryPublix = chipotles.staticTexts["Publix"]
            XCTAssertTrue(groceryPublix.exists)
            let groceryPublixMaxX = groceryPublix.frame.maxX
            app.tabBars.buttons["Catalog"].tap()
            let catalog = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "shopping.catalog.item.", "Chipotles in adobo")).firstMatch
            for _ in 0..<6 where !catalog.isHittable { app.swipeUp() }
            XCTAssertTrue(catalog.existsOrAppears(timeout: 3))
            let catalogPublix = catalog.staticTexts["Publix"]
            XCTAssertTrue(catalogPublix.exists)
            XCTAssertEqual(groceryPublixMaxX, catalogPublix.frame.maxX, accuracy: 1,
                           "Grocery and Catalog store names share the trailing column")
            app.terminate()
        }
    }

    func testEquivalentGroceryAndCatalogRowsAndSectionsMatch() {
        // Bananas has a quantity, Local honey a two-line store summary; all four exist on both pages.
        let names = ["Bananas", "Chipotles in adobo", "Local honey", "Dinner rolls"]
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
                .appendingPathComponent("EquivalentRows-\(UUID().uuidString).sqlite").path
            app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
            app.launch()
            XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
            let grocery = listMetrics(names, storeMenu: "shopping.store.menu", in: app) {
                NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "shopping.grocery.row.", "Edit \($0)")
            }
            let quantity = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                "shopping.checklist.quantity.edit.", "Edit quantity for Bananas")).firstMatch
            for _ in 0..<8 where !quantity.isHittable { app.swipeDown() }
            XCTAssertTrue(quantity.existsOrAppears(timeout: 3))
            let bananasCell = app.collectionViews.cells.containing(.button, identifier: quantity.identifier).firstMatch
            XCTAssertGreaterThanOrEqual(quantity.frame.height, 44, "Quantity keeps its 44-point hit region")
            XCTAssertGreaterThanOrEqual(quantity.frame.width, 44)
            XCTAssertTrue(bananasCell.frame.contains(quantity.frame), "The quantity hit region stays inside its row")
            attach("Equivalent grocery rows \(size)", app)
            app.tabBars.buttons["Catalog"].tap()
            XCTAssertTrue(app.navigationBars["Catalog"].existsOrAppears(timeout: 3))
            let catalog = listMetrics(names, storeMenu: "shopping.catalog.store.menu", in: app) {
                NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "shopping.catalog.item.", "\($0),")
            }
            attach("Equivalent catalog rows \(size)", app)
            XCTAssertEqual(grocery.firstHeaderTop, catalog.firstHeaderTop, accuracy: 0.5,
                           "The first category header sits the same distance below the scope controls")
            XCTAssertEqual(grocery.sectionGap, catalog.sectionGap, accuracy: 0.5, "Sections share their spacing")
            XCTAssertEqual(grocery.headerToRow, catalog.headerToRow, accuracy: 0.5)
            for name in names {
                guard let row = grocery.rows[name], let reference = catalog.rows[name] else {
                    XCTFail("\(name) was not measured on both pages at \(size)")
                    continue
                }
                let context = "\(name) at \(size)"
                XCTAssertEqual(row.cell.minX, reference.cell.minX, accuracy: 0.5, context)
                XCTAssertEqual(row.cell.width, reference.cell.width, accuracy: 0.5, context)
                XCTAssertEqual(row.titleLeading, reference.titleLeading, accuracy: 0.5, context)
                XCTAssertEqual(row.titleTop, reference.titleTop, accuracy: 0.5, context)
                XCTAssertEqual(row.storeTop, reference.storeTop, accuracy: 0.5, context)
                if name == "Bananas" {
                    // A quantity occupies the trailing edge, and at accessibility sizes its own line.
                    if size == "UICTContentSizeCategoryL" {
                        XCTAssertEqual(row.cell.height, reference.cell.height, accuracy: 0.5, context)
                    }
                } else {
                    XCTAssertEqual(row.cell.height, reference.cell.height, accuracy: 0.5, context)
                    XCTAssertEqual(row.storeTrailing, reference.storeTrailing, accuracy: 0.5, context)
                }
            }
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
                let delete = app.buttons["shopping.\(prefix).batchDelete"]
                XCTAssertTrue(delete.isEnabled)
                if screen == "Categories" {
                    assertCategoryDeleteMenuReachable(delete, in: app)
                } else {
                    XCTAssertTrue(delete.isHittable)
                }
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

    private func assertCategoryDeleteMenuReachable(_ delete: XCUIElement, in app: XCUIApplication) {
        // Referenced categories expose a native Menu. iOS 18.5 reports its
        // button as non-hittable even when a real touch opens the visible menu.
        // Prove reachability through that interaction and its exact destination.
        XCTAssertTrue(delete.existsOrAppears(timeout: 3))
        let frame = delete.frame
        XCTAssertFalse(frame.isNull || frame.isEmpty)
        XCTAssertTrue(app.frame.contains(frame))
        let navigationBar = app.navigationBars["1 Selected"]
        XCTAssertTrue(navigationBar.existsOrAppears(timeout: 3))
        let dismissalFrame = navigationBar.frame
        XCTAssertTrue(app.frame.contains(dismissalFrame))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        let destination = app.buttons["shopping.categories.deleteUncategorized"]
        XCTAssertTrue(destination.existsOrAppears(timeout: 3))
        XCTAssertTrue(destination.isHittable)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dismissalFrame.midX, dy: dismissalFrame.midY)).tap()
        XCTAssertTrue(destination.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1 Selected"].exists)
        XCTAssertTrue(delete.isEnabled)
    }

    private struct RowMetrics {
        let cell: CGRect
        let titleLeading: CGFloat
        let titleTop: CGFloat
        let storeTop: CGFloat
        let storeTrailing: CGFloat
    }

    private struct ListMetrics {
        var rows: [String: RowMetrics] = [:]
        var firstHeaderTop: CGFloat = 0
        var sectionGap: CGFloat = 0
        var headerToRow: CGFloat = 0
    }

    /// Reads the fixture's Produce, Pantry and Bakery layout from the top of a grocery or Catalog list.
    private func listMetrics(_ names: [String], storeMenu: String, in app: XCUIApplication,
                             row predicate: (String) -> NSPredicate) -> ListMetrics {
        var metrics = ListMetrics()
        let menu = app.buttons[storeMenu]
        for _ in 0..<8 where !menu.isHittable { app.swipeDown() }
        let produce = app.collectionViews.staticTexts["Produce"]
        XCTAssertTrue(produce.existsOrAppears(timeout: 3))
        metrics.firstHeaderTop = produce.frame.minY - menu.frame.maxY
        var cells: [String: XCUIElement] = [:]
        for name in names {
            let button = app.buttons.matching(predicate(name)).firstMatch
            for _ in 0..<8 where !button.isHittable { app.swipeUp() }
            guard button.existsOrAppears(timeout: 3) else {
                XCTFail("Missing row \(name)")
                continue
            }
            let cell = app.collectionViews.cells.containing(.button, identifier: button.identifier).firstMatch
            let title = button.staticTexts[name]
            let store = button.staticTexts.matching(NSPredicate(format: "label != %@", name)).firstMatch
            XCTAssertTrue(title.exists && store.exists, "\(name) shows its name and store summary")
            let frame = cell.frame
            metrics.rows[name] = RowMetrics(cell: frame, titleLeading: title.frame.minX - frame.minX,
                titleTop: title.frame.minY - frame.minY, storeTop: store.frame.minY - frame.minY,
                storeTrailing: frame.maxX - store.frame.maxX)
            cells[name] = cell
        }
        // Local honey ends Pantry and Dinner rolls is Bakery's only row on both pages.
        let bakery = app.collectionViews.staticTexts["Bakery"]
        if let honey = cells["Local honey"], let rolls = cells["Dinner rolls"], bakery.exists {
            metrics.sectionGap = bakery.frame.minY - honey.frame.maxY
            metrics.headerToRow = rolls.frame.minY - bakery.frame.maxY
        } else {
            XCTFail("The Pantry and Bakery sections must be measurable")
        }
        return metrics
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
