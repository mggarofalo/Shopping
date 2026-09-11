import XCTest

final class GroceryEditingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRememberedDraftCancelAndAtomicSaveSurviveRelaunch() {
        let app = launchApp()
        openAdd(in: app)
        let remembered = app.switches["shopping.grocery.remembered"]
        XCTAssertEqual(remembered.value as? String, "1")
        enterName("Coconut yogurt", in: app)
        setPill(app.buttons["shopping.purchase.anyStore"], selected: true, app: app)
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered items"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Groceries"].tap()

        openAdd(in: app)
        enterName("Coconut yogurt", in: app)
        setPill(app.buttons["shopping.purchase.anyStore"], selected: true, app: app)
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(groceryRow(named: "Coconut yogurt", app: app).waitForExistence(timeout: 3))
        app.tabBars.buttons["Catalog"].tap()
        let catalogRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "shopping.catalog.item.", "Coconut yogurt"
        )).firstMatch
        XCTAssertTrue(catalogRow.waitForExistence(timeout: 2))

        app.terminate()
        app.launch()
        app.tabBars.buttons["Groceries"].tap()
        let row = groceryRow(named: "Coconut yogurt", app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.grocery.quantity.add"].exists)
        attachScreenshot(named: "Remembered item editor", app: app)
    }

    func testInactiveCatalogSuggestionRequiresSelectionAndKeepsSavedDetails() {
        let app = launchApp()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 2))
        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].waitForExistence(timeout: 2))
        app.textFields["shopping.catalog.name"].typeText("Café au lait")
        app.textFields["shopping.catalog.notes"].tap()
        app.typeText("Oat milk preferred")
        app.buttons["shopping.catalog.save"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Groceries"].tap()

        openAdd(in: app)
        enterName("cafe", in: app)
        let suggestion = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.grocery.suggestion.", "Need again Café au lait"
        )).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.grocery.name"].value as? String, "cafe")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue((suggestion.value as? String)?.contains("Uncategorized · Any Store · Saved in Catalog") == true)
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))

        openAdd(in: app)
        enterName("cafe", in: app)
        XCTAssertTrue(suggestion.waitForExistence(timeout: 2))
        suggestion.tap()
        let row = groceryRow(named: "Café au lait", app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.grocery.catalogNotes"].value as? String, "Oat milk preferred")
        XCTAssertEqual(app.switches["shopping.grocery.urgency"].value as? String, "0")
    }

    func testSuggestionContextRemainsReachableAtAccessibilityTextSize() {
        let app = launchApp(
            fixture: "populated",
            contentSize: "UICTContentSizeCategoryAccessibilityXXXL"
        )
        openAdd(in: app)
        enterName("banan", in: app)
        let suggestion = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.grocery.activeMatch.", "Edit current Bananas"
        )).firstMatch

        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.textFields["shopping.grocery.name"].value as? String, "banan")
        app.buttons["shopping.grocery.keyboardDone"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        reveal(suggestion, in: app)
        XCTAssertTrue(suggestion.waitForExistence(timeout: 2))
        XCTAssertTrue(suggestion.isHittable)
        XCTAssertTrue((suggestion.value as? String)?.contains("Produce · Any Store · On grocery list") == true)
        attachScreenshot(named: "Catalog suggestion at accessibility text size", app: app)
        let name = app.textFields["shopping.grocery.name"]
        revealAbove(name, in: app)
        XCTAssertEqual(name.value as? String, "banan")
    }

    func testAddItemFocusNotesAndInlineCategoryPreserveDraftAtLargeText() {
        let app = launchApp(contentSize: "UICTContentSizeCategoryAccessibilityL")
        openAdd(in: app)

        let name = app.textFields["shopping.grocery.name"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Item notes"].exists)
        XCTAssertTrue(app.staticTexts["Temporary notes"].exists)
        name.typeText("Rice noodles")
        name.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))

        let remembered = app.switches["shopping.grocery.remembered"]
        setSwitch(remembered, on: false, app: app)
        XCTAssertFalse(app.staticTexts["Item notes"].exists)
        XCTAssertTrue(app.staticTexts["Notes"].exists)
        setSwitch(remembered, on: true, app: app)
        setPill(app.buttons["shopping.purchase.anyStore"], selected: true, app: app)

        let addCategory = app.buttons["shopping.category.add"]
        reveal(addCategory, in: app)
        addCategory.tap()
        XCTAssertTrue(app.navigationBars["Add category"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        app.typeText("Canceled category")
        app.buttons["shopping.category.cancel"].tap()

        XCTAssertTrue(app.navigationBars["Add item"].waitForExistence(timeout: 2))
        revealAbove(name, in: app)
        XCTAssertEqual(name.value as? String, "Rice noodles")
        let anyStore = app.buttons["shopping.purchase.anyStore"]
        reveal(anyStore, in: app)
        XCTAssertEqual(anyStore.value as? String, "Selected")
        reveal(addCategory, in: app)
        addCategory.tap()
        let savedCategoryName = app.textFields["shopping.category.name"]
        XCTAssertTrue(savedCategoryName.waitForExistence(timeout: 2))
        app.typeText("Noodles\n")

        XCTAssertTrue(app.navigationBars["Add item"].waitForExistence(timeout: 3))
        let noodles = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.category.", "Noodles"
        )).firstMatch
        reveal(noodles, in: app)
        XCTAssertEqual(noodles.value as? String, "Selected")
        revealAbove(name, in: app)
        XCTAssertEqual(name.value as? String, "Rice noodles")
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(groceryRow(named: "Rice noodles", app: app).waitForExistence(timeout: 3))
    }

    func testActiveMatchFocusPreservesUrgencyAndExplicitNeedAgainUncarts() {
        let app = launchApp(fixture: "populated")
        openAdd(in: app)
        enterName("Grnola", in: app)
        let match = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.activeMatch.", "Granola"
        )).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.grocery.name"].value as? String, "Grnola")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        match.tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shopping.grocery.quantity.add"].exists)
        XCTAssertEqual(app.textFields["shopping.grocery.purchaseNotes"].value as? String, "Low sugar")
        XCTAssertEqual(app.switches["shopping.grocery.urgency"].value as? String, "1")
        app.buttons["shopping.grocery.cancel"].tap()

        openAdd(in: app)
        enterName("Birthday candles", in: app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.grocery.activeMatch."
        )).count, 0, "One-time groceries must not supply Catalog suggestions")
        app.buttons["shopping.grocery.cancel"].tap()

        openAdd(in: app)
        enterName("Strawberries", in: app)
        app.buttons["Edit current Strawberries"].tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 2))
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "In cart (1)"))
            .firstMatch.waitForExistence(timeout: 3))

        openAdd(in: app)
        enterName("Strawberries", in: app)
        let needAgain = app.buttons["Need again Strawberries"]
        XCTAssertTrue(needAgain.waitForExistence(timeout: 2))
        needAgain.tap()
        let carted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "In cart (0)")).firstMatch
        XCTAssertTrue(carted.waitForExistence(timeout: 3))
        reveal(groceryRow(named: "Strawberries", app: app), in: app)
    }

    func testOneTimeIndividualRemovalAndUndoDoNotCreateCatalogKnowledge() {
        let app = launchApp()
        openAdd(in: app)
        enterName("Single-use ice", in: app)
        setSwitch(app.switches["shopping.grocery.remembered"], on: false, app: app)
        setPill(app.buttons["shopping.purchase.anyStore"], selected: true, app: app)
        app.buttons["shopping.grocery.save"].tap()
        let row = groceryRow(named: "Single-use ice", app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 2))
        let remove = app.buttons["shopping.grocery.remove"]
        reveal(remove, in: app)
        remove.tap()
        XCTAssertFalse(app.alerts.buttons["shopping.grocery.confirmRemove"].exists)
        XCTAssertTrue(app.buttons["shopping.grocery.undoRemove"].waitForExistence(timeout: 3))
        XCTAssertFalse(row.exists)
        app.buttons["shopping.grocery.undoRemove"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        XCTAssertTrue(groceryRow(named: "Single-use ice", app: app).waitForExistence(timeout: 3))
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered items"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Single-use ice"].exists)
    }

    func testStoreDefaultDoesNotOverwriteAnExistingItemsRules() {
        let app = launchApp(fixture: "populated")
        app.buttons["shopping.store.menu"].tap()
        app.buttons["Costco"].tap()

        app.buttons["shopping.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 2))
        setSwitch(app.switches["Urgent only"], on: true, app: app)
        app.navigationBars["Filters"].buttons["Done"].tap()
        openAdd(in: app)
        enterName("Bananas", in: app)
        XCTAssertFalse(app.buttons["Edit current Bananas"].exists)
        app.buttons["shopping.grocery.cancel"].tap()
        openAdd(in: app)
        enterName("Grnola", in: app)
        XCTAssertTrue(app.buttons["Edit current Granola"].waitForExistence(timeout: 2))
        app.buttons["shopping.grocery.cancel"].tap()
        app.buttons["Remove Urgent filter"].tap()

        openAdd(in: app)
        enterName("Chipotles", in: app)
        XCTAssertFalse(app.buttons["Edit current Chipotles in adobo"].exists)
        app.buttons["shopping.grocery.cancel"].tap()

        openAdd(in: app)
        enterName("Bananas", in: app)
        let match = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.activeMatch.", "Bananas"
        )).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 2))
        match.tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 2))
        let anyStore = app.buttons["shopping.purchase.anyStore"]
        reveal(anyStore, in: app)
        XCTAssertEqual(anyStore.value as? String, "Selected")
        let costco = purchaseStorePill(named: "Costco", app: app)
        reveal(costco, in: app)
        XCTAssertEqual(costco.value as? String, "Not selected")
        app.buttons["shopping.grocery.cancel"].tap()

        openAdd(in: app)
        enterName("New Costco oats", in: app)
        reveal(anyStore, in: app)
        XCTAssertEqual(anyStore.value as? String, "Not selected")
        reveal(costco, in: app)
        XCTAssertEqual(costco.value as? String, "Selected")
        attachScreenshot(named: "New item uses selected store", app: app)
        app.buttons["shopping.grocery.cancel"].tap()
    }

    func testCartedUncartOffersShowAllWhenCurrentStoreHidesTheGrocery() {
        let app = launchApp(fixture: "populated")
        app.buttons["shopping.store.menu"].tap()
        app.buttons["Publix"].tap()
        let carted = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "In cart (0)")).firstMatch
        XCTAssertTrue(carted.waitForExistence(timeout: 2))
        carted.tap()
        XCTAssertTrue(app.navigationBars["In cart"].waitForExistence(timeout: 2))
        groceryRow(named: "Strawberries", app: app).tap()
        XCTAssertTrue(app.navigationBars["Edit item"].waitForExistence(timeout: 2))
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(app.navigationBars["In cart"].waitForExistence(timeout: 2))
        XCTAssertTrue(groceryRow(named: "Strawberries", app: app).exists)
        groceryRow(named: "Strawberries", app: app).swipeLeft()
        app.buttons["Remove from cart"].tap()
        let showAll = app.buttons["shopping.grocery.showAll"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 3))
        showAll.tap()
        XCTAssertTrue(app.staticTexts["Nothing in cart"].waitForExistence(timeout: 3))
        app.navigationBars["In cart"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 3))
        reveal(groceryRow(named: "Strawberries", app: app), in: app)
        XCTAssertFalse(showAll.exists)
    }

    func testCategoryMoveAndCartFeedbackAcknowledgeRowsLeavingTheView() {
        let app = launchApp(fixture: "populated")
        XCTAssertFalse(app.staticTexts["Urgent · Pantry"].exists)

        app.buttons["shopping.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 2))
        app.buttons["Pantry"].tap()
        app.buttons["Done"].tap()

        let granola = groceryRow(named: "Granola", app: app)
        reveal(granola, in: app)
        granola.tap()
        let produce = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "shopping.category.", "Produce"
        )).firstMatch
        reveal(produce, in: app)
        produce.tap()
        app.buttons["shopping.grocery.save"].tap()

        let categoryFeedback = app.staticTexts[
            "Granola moved to Produce. Current filters hide this item."
        ]
        XCTAssertTrue(categoryFeedback.waitForExistence(timeout: 3))
        XCTAssertFalse(granola.exists)
        app.buttons["shopping.grocery.showAll"].tap()
        XCTAssertTrue(granola.waitForExistence(timeout: 3))

        reveal(granola, in: app)
        granola.swipeLeft()
        app.buttons["In cart"].tap()
        XCTAssertFalse(granola.exists)
        XCTAssertTrue(app.staticTexts["Granola moved to In cart."].waitForExistence(timeout: 3))
        attachScreenshot(named: "Category and cart acknowledgement", app: app)
    }

    private func launchApp(fixture: String? = nil, contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingEditingUITest-\(UUID().uuidString).sqlite").path
        if let fixture { app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        return app
    }

    private func openAdd(in app: XCUIApplication) {
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add from Catalog"].waitForExistence(timeout: 2))
        let addOneTime = app.buttons["shopping.grocery.addOneTime"]
        reveal(addOneTime, in: app)
        XCTAssertTrue(addOneTime.waitForExistence(timeout: 2))
        addOneTime.tap()
        XCTAssertTrue(app.navigationBars["Add item"].waitForExistence(timeout: 2))
        setSwitch(app.switches["shopping.grocery.remembered"], on: true, app: app)
    }

    private func enterName(_ name: String, in app: XCUIApplication) {
        let field = app.textFields["shopping.grocery.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText(name)
    }

    private func groceryRow(named name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.row.", name
        )).firstMatch
    }

    private func setSwitch(_ toggle: XCUIElement, on: Bool, app: XCUIApplication) {
        reveal(toggle, in: app)
        if (toggle.value as? String == "1") != on {
            let control = toggle.switches.firstMatch
            (control.exists ? control : toggle).tap()
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
    }

    private func setPill(_ pill: XCUIElement, selected: Bool, app: XCUIApplication) {
        reveal(pill, in: app)
        if (pill.value as? String == "Selected") != selected { pill.tap() }
        XCTAssertEqual(pill.value as? String, selected ? "Selected" : "Not selected")
    }

    private func purchaseStorePill(named name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "shopping.purchase.store.", name
        )).firstMatch
    }

    private func revealAbove(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
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

    private func assertMultilineField(
        _ field: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // A TextField nested in a labeled Form row reports its control bounds, while a
        // standalone TextField reports the row bounds. Compare against the two-line
        // control minimum instead of comparing those different coordinate spaces.
        XCTAssertGreaterThanOrEqual(field.frame.height, 40, file: file, line: line)
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

extension GroceryEditingUITests {
    func testNotesAndInlineQuantityAdaptAtDefaultAndAccessibilityTextSizes() {
        let contentSizes: [String?] = [nil, "UICTContentSizeCategoryAccessibilityXXXL"]
        for contentSize in contentSizes {
            let app = launchApp(contentSize: contentSize)
            openAdd(in: app)
            let name = app.textFields["shopping.grocery.name"]
            name.typeText("\n")

            let reusableNotes = app.textFields["shopping.grocery.catalogNotes"]
            let currentNotes = app.textFields["shopping.grocery.purchaseNotes"]
            XCTAssertTrue(reusableNotes.waitForExistence(timeout: 2))
            XCTAssertEqual(reusableNotes.value as? String, "Saved for future needs")
            assertMultilineField(reusableNotes)
            reveal(currentNotes, in: app)
            XCTAssertEqual(currentNotes.value as? String, "Only for this need")
            assertMultilineField(currentNotes)

            reusableNotes.tap()
            reusableNotes.typeText("A longer reusable note that remains editable across future needs")
            XCTAssertEqual(
                reusableNotes.value as? String,
                "A longer reusable note that remains editable across future needs"
            )
            let groceryKeyboardDone = app.buttons["shopping.grocery.keyboardDone"]
            XCTAssertTrue(groceryKeyboardDone.waitForExistence(timeout: 2))
            groceryKeyboardDone.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
            let remembered = app.switches["shopping.grocery.remembered"]
            revealAbove(remembered, in: app)
            setSwitch(remembered, on: false, app: app)
            reveal(currentNotes, in: app)
            XCTAssertEqual(currentNotes.value as? String, "Notes for this one-time need")
            assertMultilineField(currentNotes)
            currentNotes.tap()
            currentNotes.typeText("A longer temporary note that remains editable for this need")
            XCTAssertEqual(
                currentNotes.value as? String,
                "A longer temporary note that remains editable for this need"
            )
            revealAbove(name, in: app)
            name.tap()
            name.typeText("\n")

            let addQuantity = app.buttons["shopping.grocery.quantity.add"]
            reveal(addQuantity, in: app)
            addQuantity.tap()
            let quantity = app.steppers["shopping.grocery.quantity"]
            let clear = app.buttons["shopping.grocery.quantity.clear"]
            XCTAssertTrue(quantity.waitForExistence(timeout: 2))
            XCTAssertTrue(clear.exists)
            XCTAssertGreaterThanOrEqual(clear.frame.width, 44 - 0.01)
            XCTAssertGreaterThanOrEqual(clear.frame.height, 44 - 0.01)
            XCTAssertLessThan(abs(clear.frame.midY - quantity.frame.midY), 22)
            attachScreenshot(
                named: "Two-line notes and inline quantity - \(contentSize ?? "default")",
                app: app
            )

            app.buttons["shopping.grocery.cancel"].tap()
            app.tabBars.buttons["Catalog"].tap()
            app.buttons["shopping.catalog.add"].tap()
            XCTAssertTrue(app.navigationBars["New catalog item"].waitForExistence(timeout: 2))
            let catalogName = app.textFields["shopping.catalog.name"]
            catalogName.typeText("\n")
            let catalogNotes = app.textFields["shopping.catalog.notes"]
            XCTAssertTrue(catalogNotes.waitForExistence(timeout: 2))
            XCTAssertEqual(catalogNotes.value as? String, "Saved for future needs")
            assertMultilineField(catalogNotes)
            catalogNotes.tap()
            catalogNotes.typeText("A longer catalog note that remains editable across future needs")
            XCTAssertEqual(
                catalogNotes.value as? String,
                "A longer catalog note that remains editable across future needs"
            )
            let catalogKeyboardDone = app.buttons["shopping.catalog.keyboardDone"]
            XCTAssertTrue(catalogKeyboardDone.waitForExistence(timeout: 2))
            catalogKeyboardDone.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
            attachScreenshot(
                named: "Two-line catalog notes - \(contentSize ?? "default")",
                app: app
            )
            app.terminate()
        }
    }

    func testQuantityStartsUnsetAndCanBeAddedThenCleared() {
        let app = launchApp()
        openAdd(in: app)
        XCTAssertTrue(app.buttons["shopping.grocery.quantity.add"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.steppers["shopping.grocery.quantity"].exists)

        app.buttons["shopping.grocery.quantity.add"].tap()
        XCTAssertEqual(app.steppers["shopping.grocery.quantity"].value as? String, "1")
        let clear = app.buttons["shopping.grocery.quantity.clear"]
        XCTAssertGreaterThanOrEqual(clear.frame.width, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44 - 0.01)
        clear.tap()
        XCTAssertTrue(app.buttons["shopping.grocery.quantity.add"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.steppers["shopping.grocery.quantity"].exists)
    }
}
