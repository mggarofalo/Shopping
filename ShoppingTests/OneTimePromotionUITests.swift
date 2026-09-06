import XCTest

final class OneTimePromotionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPromotionCancelAndExplicitCreatePreserveOccurrenceAfterRelaunch() {
        let app = launchApp()
        createOneTime("Green tea", in: app)
        let originalID = row("Green tea", in: app).identifier
        row("Green tea", in: app).tap()
        startPromotion(in: app)
        replace(app.textFields["shopping.grocery.name"], with: "Canceled tea")
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(row("Green tea", in: app).waitForExistence(timeout: 3))
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered items"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Groceries"].tap()
        row("Green tea", in: app).tap()
        startPromotion(in: app)
        let catalogNotes = app.textFields["shopping.grocery.catalogNotes"]
        reveal(catalogNotes, in: app)
        catalogNotes.tap()
        catalogNotes.typeText("Loose leaf")
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(app.buttons[originalID].waitForExistence(timeout: 3))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons[originalID].waitForExistence(timeout: 5))
        app.buttons[originalID].tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.grocery.catalogNotes"].value as? String, "Loose leaf")
        XCTAssertEqual(app.textFields["shopping.grocery.purchaseNotes"].value as? String, "Buy this week")
        let quantity = quantityControls(in: app).value
        XCTAssertEqual(quantity.value as? String, "2")
        XCTAssertEqual(app.switches["shopping.grocery.urgency"].value as? String, "1")
        screenshot("Explicitly remembered grocery", app: app)
        app.buttons["shopping.grocery.cancel"].tap()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["Green tea"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Canceled tea"].exists)
    }

    func testLinkExistingUsesSavedRulesWithoutOverwritingCatalog() {
        let app = launchApp(fixture: "populated")
        row("Granola", in: app).tap()
        let remove = app.buttons["shopping.grocery.remove"]
        reveal(remove, in: app)
        remove.tap()
        app.alerts.buttons["shopping.grocery.confirmRemove"].firstMatch.tap()
        XCTAssertTrue(app.buttons["shopping.grocery.undoRemove"].waitForExistence(timeout: 3))
        createOneTime("Breakfast cereal", in: app)
        let originalID = row("Breakfast cereal", in: app).identifier
        row("Breakfast cereal", in: app).tap()
        startPromotion(in: app)
        chooseExisting("Granola", in: app)
        app.buttons["shopping.grocery.save"].tap()
        let original = app.buttons[originalID]
        reveal(original, in: app)
        XCTAssertTrue(original.label.contains("Granola"))
        original.tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 2))
        let purchaseNotes = app.textFields["shopping.grocery.purchaseNotes"]
        reveal(purchaseNotes, in: app)
        XCTAssertEqual(purchaseNotes.value as? String, "Buy this week")
        let quantity = quantityControls(in: app).value
        XCTAssertEqual(quantity.value as? String, "2")
        let urgency = app.switches["shopping.grocery.urgency"]
        reveal(urgency, in: app)
        XCTAssertEqual(urgency.value as? String, "1")
        let anyStore = app.buttons["shopping.purchase.anyStore"]
        reveal(anyStore, in: app)
        XCTAssertEqual(anyStore.value as? String, "Not selected")
        let costco = purchaseStorePill(named: "Costco", app: app)
        reveal(costco, in: app)
        XCTAssertEqual(costco.value as? String, "Selected")
        app.buttons["shopping.grocery.cancel"].tap()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertFalse(app.staticTexts["Breakfast cereal"].exists)
        XCTAssertTrue(app.staticTexts["Granola"].exists)
    }

    func testCollisionAndActiveConflictRequireExplicitDistinctChoice() {
        let app = launchApp(fixture: "populated")
        createOneTime("Granola", in: app)
        let oneTime = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND value CONTAINS[c] %@",
                "shopping.grocery.row.", "Granola", "One-time"
            )
        ).firstMatch
        reveal(oneTime, in: app)
        let originalID = oneTime.identifier
        oneTime.tap()
        startPromotion(in: app)
        app.buttons["shopping.grocery.save"].tap()
        let collision = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "shopping.grocery.promotion.collision."
            )
        ).firstMatch
        reveal(collision, in: app)
        collision.tap()
        app.buttons["shopping.grocery.save"].tap()
        let conflict = app.buttons["shopping.grocery.promotion.viewConflict"]
        reveal(conflict, in: app)
        XCTAssertTrue(conflict.exists)
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(app.buttons[originalID].waitForExistence(timeout: 3))
        XCTAssertTrue(
            (app.buttons[originalID].value as? String ?? "").localizedCaseInsensitiveContains("One-time"))
        app.buttons[originalID].tap()
        startPromotion(in: app)
        app.buttons["shopping.grocery.save"].tap()
        let distinct = app.buttons["shopping.grocery.createDistinct"]
        reveal(distinct, in: app)
        distinct.tap()
        XCTAssertTrue(app.buttons[originalID].waitForExistence(timeout: 3))
        XCTAssertFalse(
            (app.buttons[originalID].value as? String ?? "").localizedCaseInsensitiveContains("One-time"))
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                    "shopping.grocery.row.", "Granola"
                )
            ).count, 2)
    }

    func testCartedUrgentGroceriesSortBeforeNormalGroceries() {
        let app = launchApp(fixture: "populated")
        let bananasRow = row("Bananas", in: app)
        reveal(bananasRow, in: app)
        bananasRow.swipeLeft()
        app.buttons["In cart"].tap()
        let granolaRow = row("Granola", in: app)
        for _ in 0..<8 where !granolaRow.exists || !granolaRow.isHittable { app.swipeDown() }
        XCTAssertTrue(granolaRow.isHittable)
        granolaRow.swipeLeft()
        app.buttons["In cart"].tap()
        let carted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "In cart (3)")).firstMatch
        for _ in 0..<8 where !carted.exists || !carted.isHittable { app.swipeDown() }
        XCTAssertTrue(carted.waitForExistence(timeout: 3))
        carted.tap()
        XCTAssertTrue(app.navigationBars["In cart"].waitForExistence(timeout: 2))
        let granola = row("Granola", in: app)
        let bananas = row("Bananas", in: app)
        XCTAssertTrue(granola.waitForExistence(timeout: 3))
        XCTAssertTrue(bananas.exists)
        XCTAssertLessThan(granola.frame.minY, bananas.frame.minY)
    }

    private func launchApp(fixture: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingPromotionUITest-\(UUID().uuidString).sqlite").path
        if let fixture { app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture }
        app.launch()
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        return app
    }

    private func createOneTime(_ name: String, in app: XCUIApplication) {
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add item"].waitForExistence(timeout: 2))
        let remembered = app.switches["shopping.grocery.remembered"]
        setSwitch(remembered, on: false, in: app)
        let field = app.textFields["shopping.grocery.name"]
        field.tap()
        field.typeText(name)
        field.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        let quantity = quantityControls(in: app)
        quantity.increment.tap()
        XCTAssertEqual(quantity.value.value as? String, "2")
        setSwitch(app.switches["shopping.grocery.urgency"], on: true, in: app)
        setPill(app.buttons["shopping.purchase.anyStore"], selected: true, in: app)
        let notes = app.textFields["shopping.grocery.purchaseNotes"]
        for _ in 0..<10 where !notes.exists { app.swipeDown() }
        reveal(notes, in: app)
        notes.tap()
        notes.typeText("Buy this week")
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 3))
        reveal(row(name, in: app), in: app)
    }

    private func startPromotion(in app: XCUIApplication) {
        let start = app.buttons["shopping.grocery.promotion.start"]
        reveal(start, in: app)
        start.tap()
        XCTAssertTrue(app.segmentedControls["shopping.grocery.promotion.choice"].waitForExistence(timeout: 2))
    }

    private func chooseExisting(_ name: String, in app: XCUIApplication) {
        app.segmentedControls["shopping.grocery.promotion.choice"].buttons["Use existing"].tap()
        let search = app.textFields["shopping.grocery.promotion.search"]
        reveal(search, in: app)
        search.tap()
        search.typeText(name)
        search.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        let match = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "shopping.grocery.promotion.item.", name
            )
        ).firstMatch
        reveal(match, in: app)
        match.tap()
    }

    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "shopping.grocery.row.", name
            )
        ).firstMatch
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        if let value = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    private func setSwitch(_ element: XCUIElement, on: Bool, in app: XCUIApplication) {
        reveal(element, in: app)
        if (element.value as? String == "1") != on {
            let inner = element.switches.firstMatch
            (inner.exists ? inner : element).tap()
        }
        XCTAssertEqual(element.value as? String, on ? "1" : "0")
    }

    private func setPill(_ pill: XCUIElement, selected: Bool, in app: XCUIApplication) {
        reveal(pill, in: app)
        if (pill.value as? String == "Selected") != selected { pill.tap() }
        XCTAssertEqual(pill.value as? String, selected ? "Selected" : "Not selected")
    }

    private func purchaseStorePill(named name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "shopping.purchase.store.", name
        )).firstMatch
    }

    private func quantityControls(in app: XCUIApplication) -> (value: XCUIElement, increment: XCUIElement) {
        let quantity = app.steppers["shopping.grocery.quantity"]
        let increments = quantity.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@",
            "shopping.grocery.quantity-Increment", "Increment"
        ))
        // iOS 18 exposes the Stepper's actionable children as hittable, while
        // the fully visible value container itself is not a tap target.
        let increment = increments.firstMatch
        reveal(increment, in: app)
        XCTAssertEqual(increments.count, 1)
        XCTAssertTrue(quantity.exists)
        return (quantity, increment)
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

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
