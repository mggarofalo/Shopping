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
        let anyStore = app.buttons["shopping.purchase.anyStore"]
        reveal(anyStore, app: app)
        if anyStore.value as? String != "Selected" { anyStore.tap() }
        app.buttons["shopping.grocery.save"].tap()
        let row = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "shopping.grocery.row.", "Fresh ice"
            )
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let originalID = row.identifier
        row.swipeLeft()
        app.buttons["In cart"].tap()
        let carted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "In cart (1)")).firstMatch
        XCTAssertTrue(carted.waitForExistence(timeout: 3))
        carted.tap()
        let clear = app.buttons["shopping.carted.clear"]
        reveal(clear, app: app)
        clear.tap()
        XCTAssertTrue(app.navigationBars["Clear items in cart?"].waitForExistence(timeout: 2))
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
        app.navigationBars["In cart"].buttons.firstMatch.tap()
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
}
