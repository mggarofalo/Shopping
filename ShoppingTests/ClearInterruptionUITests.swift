import XCTest

final class ClearInterruptionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCommittedOneTimeClearRecoversAfterExitBeforeUIAcknowledgement() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingClearInterruption-\(UUID().uuidString).sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_EXIT_AFTER_CLEAR"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        app.buttons["shopping.addGrocery"].tap()
        let name = app.textFields["shopping.grocery.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.tap()
        name.typeText("Fresh ice")
        setSwitch(app.switches["shopping.grocery.remembered"], on: false, app: app)
        let notes = app.textFields["shopping.grocery.purchaseNotes"]
        reveal(notes, app: app)
        notes.tap()
        notes.typeText("Keep cold")
        setSwitch(app.switches["Any store"], on: true, app: app)
        app.buttons["shopping.grocery.save"].tap()
        let row = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "shopping.grocery.row.", "Fresh ice"
            )
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let originalID = row.identifier
        app.buttons["Cart Fresh ice"].tap()
        let carted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Carted (1)")).firstMatch
        XCTAssertTrue(carted.waitForExistence(timeout: 3))
        carted.tap()
        let clear = app.buttons["shopping.carted.clear"]
        reveal(clear, app: app)
        clear.tap()
        XCTAssertTrue(app.navigationBars["Clear carted?"].waitForExistence(timeout: 2))
        app.buttons["shopping.clear.confirm"].tap()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))

        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_EXIT_AFTER_CLEAR")
        app.launch()
        let recentlyCleared = app.buttons["Recently cleared"]
        XCTAssertTrue(recentlyCleared.waitForExistence(timeout: 5))
        recentlyCleared.tap()
        let restore = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "shopping.recovery.restore."
            )
        ).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()
        app.navigationBars["Recently cleared"].buttons.firstMatch.tap()
        XCTAssertTrue(carted.waitForExistence(timeout: 3))
        carted.tap()
        let recovered = app.buttons[originalID]
        XCTAssertTrue(recovered.waitForExistence(timeout: 3))
        recovered.tap()
        XCTAssertEqual(app.textFields["shopping.grocery.purchaseNotes"].value as? String, "Keep cold")
        XCTAssertTrue(app.descendants(matching: .any)["shopping.grocery.oneTime"].exists)
        app.buttons["shopping.grocery.cancel"].tap()
        app.navigationBars["Carted"].buttons.firstMatch.tap()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered groceries"].waitForExistence(timeout: 3))
    }

    private func setSwitch(_ toggle: XCUIElement, on: Bool, app: XCUIApplication) {
        reveal(toggle, app: app)
        if (toggle.value as? String == "1") != on {
            let inner = toggle.switches.firstMatch
            (inner.exists ? inner : toggle).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }
}
