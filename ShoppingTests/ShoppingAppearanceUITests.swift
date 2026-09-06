import XCTest

final class ShoppingAppearanceUITests: XCTestCase {
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
                XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
                attach("Groceries \(appearance) \(size)", app)
                app.buttons["shopping.filters"].tap()
                XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 3))
                attach("Grocery filters \(appearance) \(size)", app)
                app.buttons["Done"].tap()
                app.buttons["shopping.addGrocery"].tap()
                XCTAssertTrue(app.navigationBars["Add item"].waitForExistence(timeout: 3))
                attach("Grocery editor \(appearance) \(size)", app)
                app.buttons["shopping.grocery.cancel"].tap()
                app.tabBars.buttons["Catalog"].tap()
                app.buttons["shopping.catalog.filters"].tap()
                XCTAssertTrue(app.navigationBars["Catalog filters"].waitForExistence(timeout: 3))
                attach("Catalog filters \(appearance) \(size)", app)
                app.buttons["Done"].tap()
                app.buttons["shopping.catalog.add"].tap()
                XCTAssertTrue(app.navigationBars["New catalog item"].waitForExistence(timeout: 3))
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
                XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
                app.tabBars.buttons["Catalog"].tap()
                let list = app.collectionViews["shopping.catalog.list"]
                XCTAssertTrue(list.waitForExistence(timeout: 3))
                let firstItem = app.buttons.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@", "shopping.catalog.item."
                )).firstMatch
                XCTAssertTrue(firstItem.waitForExistence(timeout: 3))
                let firstCell = list.cells.containing(.button, identifier: firstItem.identifier).firstMatch
                XCTAssertTrue(firstCell.waitForExistence(timeout: 3))
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

    func testAppearanceChoicePersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] =
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "Appearance-\(UUID().uuidString).sqlite"
            ).path
        defer { select("System", in: app) }
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        openSettings(app)
        let scheme = app.segmentedControls["shopping.appearance"]
        XCTAssertTrue(scheme.waitForExistence(timeout: 3))
        scheme.buttons["Light"].tap()
        attach("Light appearance", app)
        scheme.buttons["Dark"].tap()
        XCTAssertTrue(scheme.buttons["Dark"].isSelected)
        attach("Dark appearance", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        openSettings(app)
        XCTAssertTrue(app.segmentedControls["shopping.appearance"].buttons["Dark"].isSelected)
    }

    private func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
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
