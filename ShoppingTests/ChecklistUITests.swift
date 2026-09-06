import XCTest

final class ChecklistUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testFilteredClearPreviewCancelAndUndoPreserveOtherStoreGroceries() {
        let app = launchApp(fixture: "populated")
        selectStore("Publix", app: app)
        XCTAssertTrue(cartedLink(count: 0, app: app).waitForExistence(timeout: 2))
        cart("Birthday candles", app: app)
        cart("Chipotles in adobo", app: app)
        reveal(cartedLink(count: 2, app: app), app: app, upwards: false)
        cartedLink(count: 2, app: app).tap()
        XCTAssertTrue(app.navigationBars["Carted"].waitForExistence(timeout: 2))
        XCTAssertFalse(row("Strawberries", app: app).exists)

        openClear(app: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Publix")).firstMatch.exists)
        XCTAssertTrue(app.buttons["shopping.clear.confirm"].label.contains("2"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Birthday candles")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Chipotles in adobo")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Strawberries")).firstMatch.exists)
        attachScreenshot("Scoped clear preview", app: app)
        app.buttons["shopping.clear.cancel"].tap()
        XCTAssertTrue(row("Birthday candles", app: app).waitForExistence(timeout: 2))
        XCTAssertTrue(row("Chipotles in adobo", app: app).exists)

        openClear(app: app)
        app.buttons["shopping.clear.confirm"].tap()
        let undo = app.buttons["shopping.clear.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertFalse(row("Birthday candles", app: app).exists)
        XCTAssertFalse(row("Chipotles in adobo", app: app).exists)
        undo.tap()
        XCTAssertTrue(row("Birthday candles", app: app).waitForExistence(timeout: 3))
        reveal(row("Chipotles in adobo", app: app), app: app)
        app.buttons["shopping.carted.all"].tap()
        reveal(row("Strawberries", app: app), app: app)
        XCTAssertFalse(app.buttons["Delete all groceries"].exists)
    }

    func testOneTimeClearRecoverySurvivesRelaunchWithoutRemembering() {
        let app = launchApp()
        app.buttons["shopping.addGrocery"].tap()
        let name = app.textFields["shopping.grocery.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.tap()
        name.typeText("Weekend ice")
        setSwitch(app.switches["shopping.grocery.remembered"], on: false, app: app)
        setSwitch(app.switches["Any store"], on: true, app: app)
        app.buttons["shopping.grocery.save"].tap()
        cart("Weekend ice", app: app)
        cartedLink(count: 1, app: app).tap()
        openClear(app: app)
        app.buttons["shopping.clear.confirm"].tap()
        XCTAssertTrue(app.buttons["shopping.clear.undo"].waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        app.buttons["Recently cleared"].tap()
        let restore = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.recovery.restore."
        )).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()
        app.navigationBars["Recently cleared"].buttons.firstMatch.tap()
        XCTAssertTrue(cartedLink(count: 1, app: app).waitForExistence(timeout: 3))
        cartedLink(count: 1, app: app).tap()
        XCTAssertTrue(row("Weekend ice", app: app).waitForExistence(timeout: 2))
        app.buttons["Uncart Weekend ice"].tap()
        app.navigationBars["Carted"].buttons.firstMatch.tap()
        XCTAssertTrue(row("Weekend ice", app: app).waitForExistence(timeout: 3))
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered groceries"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Weekend ice"].exists)
    }

    func testQuickQuantityAndUncartPreserveUrgencyNotesAndPersist() {
        let app = launchApp(fixture: "populated")
        selectStore("Costco", app: app)
        let quantity = app.buttons["Increase quantity for Granola"]
        reveal(quantity, app: app)
        XCTAssertGreaterThanOrEqual(quantity.frame.height, 44 - 0.01)
        quantity.tap()
        cart("Granola", app: app)
        reveal(cartedLink(count: 2, app: app), app: app, upwards: false)
        cartedLink(count: 2, app: app).tap()
        let uncart = app.buttons["Uncart Granola"]
        reveal(uncart, app: app)
        XCTAssertGreaterThanOrEqual(uncart.frame.height, 44 - 0.01)
        uncart.tap()
        app.navigationBars["Carted"].buttons.firstMatch.tap()
        reveal(row("Granola", app: app), app: app)

        app.terminate()
        // A populated fixture is created once; the relaunch must reopen its saved store.
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        selectStore("Costco", app: app)
        reveal(row("Granola", app: app), app: app)
        row("Granola", app: app).tap()
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.grocery.quantity"].value as? String, "2")
        XCTAssertEqual(app.textFields["shopping.grocery.purchaseNotes"].value as? String, "Low sugar")
        XCTAssertTrue(app.segmentedControls["shopping.grocery.urgency"].buttons["Urgent"].isSelected)
    }

    func testChecklistControlsRemainUsableAtAccessibilityTextSize() {
        let app = launchApp(fixture: "populated", largeText: true)
        selectStore("Costco", app: app)
        let cart = app.buttons["Cart Granola"]
        reveal(cart, app: app)
        XCTAssertGreaterThanOrEqual(cart.frame.height, 44 - 0.01)
        let quantity = app.buttons["Increase quantity for Granola"]
        reveal(quantity, app: app)
        XCTAssertGreaterThanOrEqual(quantity.frame.height, 44 - 0.01)
        attachScreenshot("Checklist at accessibility text size", app: app)
        reveal(cart, app: app)
        cart.tap()
        XCTAssertFalse(cart.exists)
    }

    private func launchApp(fixture: String? = nil, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if largeText {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingChecklistUITest-\(UUID().uuidString).sqlite").path
        if let fixture { app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture }
        app.launch()
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        return app
    }

    private func selectStore(_ name: String, app: XCUIApplication) {
        app.buttons["shopping.store.menu"].tap()
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", name, "shopping.store.menu"
        )).firstMatch.tap()
    }

    private func cart(_ name: String, app: XCUIApplication) {
        let button = app.buttons["Cart \(name)"]
        reveal(button, app: app)
        button.tap()
        XCTAssertFalse(button.exists)
    }

    private func cartedLink(count: Int, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Carted (\(count))")).firstMatch
    }

    private func row(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "shopping.grocery.row.", name
        )).firstMatch
    }

    private func openClear(app: XCUIApplication) {
        let clear = app.buttons["shopping.carted.clear"]
        reveal(clear, app: app)
        clear.tap()
        XCTAssertTrue(app.buttons["shopping.clear.confirm"].waitForExistence(timeout: 2))
    }

    private func setSwitch(_ toggle: XCUIElement, on: Bool, app: XCUIApplication) {
        reveal(toggle, app: app)
        if (toggle.value as? String == "1") != on {
            let control = toggle.switches.firstMatch
            (control.exists ? control : toggle).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication, upwards: Bool = true) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            if upwards { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
