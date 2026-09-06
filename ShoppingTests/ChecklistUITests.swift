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
        XCTAssertTrue(app.navigationBars["In cart"].waitForExistence(timeout: 2))
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
        let anyStore = app.buttons["shopping.purchase.anyStore"]
        reveal(anyStore, app: app)
        if anyStore.value as? String != "Selected" { anyStore.tap() }
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
        uncart("Weekend ice", app: app)
        app.navigationBars["In cart"].buttons.firstMatch.tap()
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
        uncart("Granola", app: app)
        app.navigationBars["In cart"].buttons.firstMatch.tap()
        reveal(row("Granola", app: app), app: app)

        app.terminate()
        // A populated fixture is created once; the relaunch must reopen its saved store.
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        selectStore("Costco", app: app)
        reveal(row("Granola", app: app), app: app)
        row("Granola", app: app).tap()
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.steppers["shopping.grocery.quantity"].value as? String, "2")
        XCTAssertEqual(app.textFields["shopping.grocery.purchaseNotes"].value as? String, "Low sugar")
        XCTAssertEqual(app.switches["shopping.grocery.urgency"].value as? String, "1")
    }

    func testChecklistControlsRemainUsableAtAccessibilityTextSize() {
        let app = launchApp(fixture: "populated", largeText: true)
        selectStore("Costco", app: app)
        let granola = row("Granola", app: app)
        reveal(granola, app: app)
        XCTAssertGreaterThanOrEqual(granola.frame.height, 44 - 0.01)
        let quantity = app.buttons["Increase quantity for Granola"]
        reveal(quantity, app: app)
        XCTAssertGreaterThanOrEqual(quantity.frame.height, 44 - 0.01)
        attachScreenshot("Checklist at accessibility text size", app: app)
        fullSwipeLeft(granola, app: app)
        XCTAssertFalse(granola.exists)
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
        let grocery = row(name, app: app)
        reveal(grocery, app: app)
        revealSwipeAction("In cart", for: grocery, app: app)
        app.buttons["In cart"].tap()
        XCTAssertFalse(grocery.exists)
    }

    private func uncart(_ name: String, app: XCUIApplication) {
        let grocery = row(name, app: app)
        reveal(grocery, app: app)
        revealSwipeAction("Remove from cart", for: grocery, app: app)
        app.buttons["Remove from cart"].tap()
        XCTAssertFalse(grocery.exists)
    }

    private func revealSwipeAction(_ label: String, for row: XCUIElement, app: XCUIApplication) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 2))
    }

    private func fullSwipeLeft(_ row: XCUIElement, app: XCUIApplication) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(
            dx: 0.01,
            dy: row.frame.midY / app.frame.height
        ))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func cartedLink(count: Int, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "In cart (\(count))")).firstMatch
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
            } else if !upwards {
                drag(in: app, x: x, from: upper, to: lower)
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

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
