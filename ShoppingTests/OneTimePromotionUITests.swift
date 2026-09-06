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
        XCTAssertTrue(app.staticTexts["No remembered groceries"].waitForExistence(timeout: 2))
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
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.grocery.catalogNotes"].value as? String, "Loose leaf")
        XCTAssertEqual(app.textFields["shopping.grocery.purchaseNotes"].value as? String, "Buy this week")
        XCTAssertEqual(app.textFields["shopping.grocery.quantity"].value as? String, "2")
        XCTAssertTrue(app.segmentedControls["shopping.grocery.urgency"].buttons["Urgent"].isSelected)
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
        XCTAssertTrue(app.navigationBars["Edit grocery"].waitForExistence(timeout: 2))
        let purchaseNotes = app.textFields["shopping.grocery.purchaseNotes"]
        reveal(purchaseNotes, in: app)
        XCTAssertEqual(purchaseNotes.value as? String, "Buy this week")
        let quantity = app.textFields["shopping.grocery.quantity"]
        reveal(quantity, in: app)
        XCTAssertEqual(quantity.value as? String, "2")
        let urgency = app.segmentedControls["shopping.grocery.urgency"].buttons["Urgent"]
        reveal(urgency, in: app)
        XCTAssertTrue(urgency.isSelected)
        let anyStore = app.switches["Any store"]
        reveal(anyStore, in: app)
        XCTAssertEqual(anyStore.value as? String, "0")
        let costco = app.switches["Costco"]
        reveal(costco, in: app)
        XCTAssertEqual(costco.value as? String, "1")
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
        let cartBananas = app.buttons["Cart Bananas"]
        reveal(cartBananas, in: app)
        cartBananas.tap()
        let cartGranola = app.buttons["Cart Granola"]
        for _ in 0..<8 where !cartGranola.exists || !cartGranola.isHittable { app.swipeDown() }
        XCTAssertTrue(cartGranola.isHittable)
        cartGranola.tap()
        let carted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Carted (3)")).firstMatch
        for _ in 0..<8 where !carted.exists || !carted.isHittable { app.swipeDown() }
        XCTAssertTrue(carted.waitForExistence(timeout: 3))
        carted.tap()
        XCTAssertTrue(app.navigationBars["Carted"].waitForExistence(timeout: 2))
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
        XCTAssertTrue(app.navigationBars["Add grocery"].waitForExistence(timeout: 2))
        let remembered = app.switches["shopping.grocery.remembered"]
        setSwitch(remembered, on: false, in: app)
        let field = app.textFields["shopping.grocery.name"]
        field.tap()
        field.typeText(name)
        let notes = app.textFields["shopping.grocery.purchaseNotes"]
        reveal(notes, in: app)
        notes.tap()
        notes.typeText("Buy this week")
        let quantity = app.textFields["shopping.grocery.quantity"]
        reveal(quantity, in: app)
        replace(quantity, with: "2")
        let urgent = app.segmentedControls["shopping.grocery.urgency"].buttons["Urgent"]
        reveal(urgent, in: app)
        urgent.tap()
        setSwitch(app.switches["Any store"], on: true, in: app)
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

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            let appFrame = app.frame
            let navigationFrame = app.navigationBars.firstMatch.frame
            guard usable(appFrame), usable(navigationFrame) else { continue }
            let fixedScope = app.otherElements["shopping.grocery.fixedScope"]
            let targetIsInFixedScope = contains(element, in: fixedScope)
            let fixedScopeFrame = fixedScope.exists && fixedScope.isHittable && !targetIsInFixedScope
                ? fixedScope.frame : nil
            if let fixedScopeFrame, !usable(fixedScopeFrame) { continue }
            let top = max(navigationFrame.maxY, fixedScopeFrame?.maxY ?? navigationFrame.maxY)
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
