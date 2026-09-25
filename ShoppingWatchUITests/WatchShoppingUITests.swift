import XCTest

final class WatchShoppingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testUnimportedReplicaShowsSetupWithoutDemoGroceries() {
        let app = launchDurableFixture("setup")
        XCTAssertTrue(app.staticTexts["Set up Shopping"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["watch.store.switch"].exists)
        screenshot("Watch isolated unimported replica setup", app: app)
    }

    func testStoreTitleSwitchAndNativeSwipeCart() {
        let app = launchFixture()
        let switcher = storeSwitcher(in: app)
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertTrue(switcher.isHittable)
        XCTAssertLessThanOrEqual(switcher.frame.maxX, app.frame.maxX - 40)
        assertBottomAction(app.buttons["watch.cart.open"], in: app)
        assertBottomAction(app.buttons["watch.checkout.open"], in: app)
        screenshot("Watch compact grocery root", app: app)
        switcher.tap()
        let costco = app.buttons["watch.store.10000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(costco.waitForExistence(timeout: 3))
        XCTAssertEqual(costco.value as? String, "0 only buy here, 2 can buy here")
        let traderJoes = app.buttons["watch.store.10000000-0000-0000-0000-000000000001"]
        XCTAssertEqual(traderJoes.value as? String, "Selected. 1 only buy here, 2 can buy here")
        screenshot("Watch store purchase counts", app: app)
        costco.tap()
        XCTAssertTrue(switcher.waitForExistence(timeout: 3))
        XCTAssertTrue(switcher.label.contains("Costco"))
        XCTAssertFalse(app.buttons["watch.item.strawberries"].exists)
        let bananas = app.buttons["watch.item.bananas"]
        reveal(bananas, in: app)
        bananas.swipeLeft()
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        app.buttons["watch.cart.open"].tap()
        XCTAssertTrue(app.navigationBars["In cart"].waitForExistence(timeout: 3))
        reveal(bananas, in: app)
        screenshot("Watch cart with floating checkout", app: app)
        XCTAssertTrue(app.buttons["watch.checkout.open"].isEnabled)
        bananas.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertFalse(bananas.exists)
    }

    func testPurchaseNoticeCardCheckoutAndRecovery() {
        let app = launchFixture()
        let cart = app.buttons["watch.cart.open"]
        XCTAssertTrue(cart.waitForExistence(timeout: 5))
        cart.tap()
        let milk = app.buttons["watch.item.milk"]
        reveal(milk, in: app)
        screenshot("Watch milk before card", app: app)
        milk.tap()
        XCTAssertTrue(app.navigationBars["Item"].waitForExistence(timeout: 3))
        let buyAnyway = app.buttons["watch.item.buyAnyway"]
        reveal(buyAnyway, in: app)
        screenshot("Watch already purchased choice", app: app)
        buyAnyway.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["watch.checkout.open"].tap()
        let confirm = app.buttons["watch.checkout.confirm"]
        reveal(confirm, in: app)
        screenshot("Watch captured checkout", app: app)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["1 item cleared"].waitForExistence(timeout: 5))
        reveal(app.buttons["Done"], in: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Your cart is empty"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["watch.checkout.open"].isEnabled)
        app.navigationBars.buttons.firstMatch.tap()
        storeSwitcher(in: app).tap()
        let recent = app.buttons["Recently cleared"]
        reveal(recent, in: app)
        recent.tap()
        let restore = app.buttons["Restore items"]
        reveal(restore, in: app)
        restore.tap()
        app.buttons["Restore items"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Items restored"].waitForExistence(timeout: 5))
    }

    func testFinalCartRowClearsFloatingCheckout() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_WATCH_FIXTURE"] = "fullCart"
        app.launch()
        XCTAssertTrue(app.buttons["watch.cart.open"].waitForExistence(timeout: 5))
        app.buttons["watch.cart.open"].tap()
        let last = app.buttons["watch.item.granola"]
        reveal(last, in: app)
        XCTAssertLessThanOrEqual(last.frame.maxY, app.buttons["watch.checkout.open"].frame.minY - 2)
        XCTAssertGreaterThanOrEqual(app.buttons["watch.checkout.open"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(last.frame.height, 44)
        screenshot("Watch final row clear of checkout", app: app)
        last.tap()
        XCTAssertTrue(app.navigationBars["Item"].waitForExistence(timeout: 3))
    }

    func testCompactItemControlsAndPinnedAdd() {
        let app = launchFixture()
        let granola = app.buttons["watch.item.granola"]
        reveal(granola, in: app)
        XCTAssertLessThanOrEqual(granola.frame.maxY, app.buttons["watch.cart.open"].frame.minY - 2)
        granola.tap()
        XCTAssertTrue(app.navigationBars["Item"].waitForExistence(timeout: 3))
        screenshot("Watch compact item summary", app: app)
        let add = app.buttons["watch.item.add"]
        assertBottomAction(add, in: app)
        let increase = app.buttons["Increase your quantity"]
        reveal(increase, in: app)
        XCTAssertGreaterThanOrEqual(increase.frame.height, 44)
        XCTAssertGreaterThanOrEqual(increase.frame.width, 44)
        XCTAssertLessThanOrEqual(increase.frame.width, 60)
        increase.tap()
        XCTAssertEqual(increase.value as? String, "1")
        let clear = app.buttons["Clear quantity"]
        reveal(clear, in: app)
        XCTAssertLessThanOrEqual(clear.frame.maxY, add.frame.minY - 2)
        screenshot("Watch compact item and floating add", app: app)
        add.tap()
        assertReturnedToGroceries(app)
        XCTAssertFalse(granola.exists)
        app.buttons["watch.cart.open"].tap()
        reveal(granola, in: app)
        XCTAssertTrue((granola.value as? String ?? "").contains("Quantity 1"))
    }

    func testFailedCardAddKeepsDraftAndAllowsRetry() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_WATCH_FIXTURE"] = "addFailure"
        app.launch()
        let granola = app.buttons["watch.item.granola"]
        reveal(granola, in: app)
        granola.tap()
        XCTAssertTrue(app.navigationBars["Item"].waitForExistence(timeout: 3))
        let increase = app.buttons["Increase your quantity"]
        reveal(increase, in: app)
        increase.tap()
        increase.tap()
        XCTAssertEqual(increase.value as? String, "2")
        let add = app.buttons["watch.item.add"]
        add.tap()
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.staticTexts.matching(NSPredicate(
            format: "label == %@", "Preview add failed. Your cart is unchanged. Try again."
        )).count, 0)
        screenshot("Watch failed add retains card", app: app)
        app.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Item"].waitForExistence(timeout: 3))
        reveal(increase, in: app)
        XCTAssertEqual(increase.value as? String, "2")
        XCTAssertTrue(add.isEnabled)
        add.tap()
        assertReturnedToGroceries(app)
        XCTAssertFalse(granola.exists)
        app.buttons["watch.cart.open"].tap()
        reveal(granola, in: app)
        XCTAssertTrue((granola.value as? String ?? "").contains("Quantity 2"))
    }

    func testDurableCardAddDismissesAndQuantitySurvivesRelaunch() {
        let app = launchDurableFixture("ready")
        selectMarketIfNeeded(app)
        let milk = app.buttons.matching(NSPredicate(format: "label == %@", "Milk")).element
        reveal(milk, in: app)
        let groceryIdentifier = milk.identifier
        milk.tap()
        XCTAssertTrue(app.navigationBars["Item"].waitForExistence(timeout: 3))
        let increase = app.buttons["Increase your quantity"]
        reveal(increase, in: app)
        increase.tap()
        increase.tap()
        XCTAssertEqual(increase.value as? String, "2")
        app.buttons["watch.item.add"].tap()
        assertReturnedToGroceries(app)
        XCTAssertFalse(milk.exists)
        app.buttons["watch.cart.open"].tap()
        reveal(milk, in: app)
        XCTAssertTrue((milk.value as? String ?? "").contains("Quantity 2"))
        let cartIdentifier = milk.identifier
        XCTAssertNotEqual(cartIdentifier, groceryIdentifier)
        app.terminate()
        app.launch()
        selectMarketIfNeeded(app)
        app.buttons["watch.cart.open"].tap()
        reveal(milk, in: app)
        XCTAssertEqual(milk.identifier, cartIdentifier)
        XCTAssertTrue((milk.value as? String ?? "").contains("Quantity 2"))
        screenshot("Watch durable card add after relaunch", app: app)
    }

    func testEmptyListKeepsActionsAtScreenBottom() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_WATCH_FIXTURE"] = "empty"
        app.launch()
        let cart = app.buttons["watch.cart.open"]
        XCTAssertTrue(cart.waitForExistence(timeout: 5))
        assertBottomAction(cart, in: app)
        assertBottomAction(app.buttons["watch.checkout.open"], in: app)
        screenshot("Watch empty grocery bottom actions", app: app)
        cart.tap()
        XCTAssertTrue(app.staticTexts["Your cart is empty"].waitForExistence(timeout: 3))
        assertBottomAction(app.buttons["watch.checkout.open"], in: app)
        XCTAssertFalse(app.buttons["watch.checkout.open"].isEnabled)
    }

    func testLongNameRemainsAccessibleAtLargeText() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_WATCH_FIXTURE"] = "longNames"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let item = app.buttons["watch.item.bananas"]
        reveal(item, in: app, allowOversizedRow: true)
        XCTAssertEqual(item.label, "Organic Fair Trade Cavendish Bananas")
        XCTAssertTrue((item.value as? String ?? "").contains("Can buy here"))
        screenshot("Watch long name large text", app: app)
        item.tap()
        XCTAssertTrue(app.navigationBars["Item"].waitForExistence(timeout: 3))
        screenshot("Watch long item detail large text", app: app)
        app.navigationBars.buttons.firstMatch.tap()
        storeSwitcher(in: app).tap()
        let costco = app.buttons["watch.store.10000000-0000-0000-0000-000000000002"]
        reveal(costco, in: app)
        XCTAssertEqual(costco.value as? String, "0 only buy here, 2 can buy here")
        screenshot("Watch store counts large text", app: app)
    }

    func testFailedCheckoutShowsErrorAndKeepsPreviewForRetry() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_WATCH_FIXTURE"] = "saveFailure"
        app.launch()
        let checkout = app.buttons["watch.checkout.open"]
        XCTAssertTrue(checkout.waitForExistence(timeout: 5))
        checkout.tap()
        let confirm = app.buttons["watch.checkout.confirm"]
        reveal(confirm, in: app)
        confirm.tap()
        // watchOS presents native alerts as a full-screen table, not XCUIElementTypeAlert.
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.staticTexts.matching(NSPredicate(
            format: "label == %@", "Preview save failed. Your cart is unchanged. Try again."
        )).count, 0)
        screenshot("Watch checkout save failure", app: app)
        app.buttons["OK"].tap()
        reveal(confirm, in: app)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["3 items cleared"].waitForExistence(timeout: 5))
    }

    func testDurableQuantityCheckoutRelaunchAndRestore() {
        let app = launchDurableFixture("ready")
        selectMarketIfNeeded(app)
        let milk = app.buttons.matching(NSPredicate(format: "label == %@", "Milk")).element
        reveal(milk, in: app)
        milk.swipeLeft()
        app.buttons["Add"].tap()
        app.buttons["watch.cart.open"].tap()
        reveal(milk, in: app)
        milk.tap()
        let increase = app.buttons["Increase your quantity"]
        reveal(increase, in: app)
        increase.tap()
        XCTAssertTrue(app.staticTexts["1"].waitForExistence(timeout: 3))
        increase.tap()
        XCTAssertTrue(app.staticTexts["2"].waitForExistence(timeout: 3))
        app.terminate()
        app.launch()
        selectMarketIfNeeded(app)
        app.buttons["watch.cart.open"].tap()
        reveal(milk, in: app)
        XCTAssertTrue((milk.value as? String ?? "").contains("Quantity 2"))
        app.buttons["watch.checkout.open"].tap()
        let confirm = app.buttons["watch.checkout.confirm"]
        reveal(confirm, in: app)
        confirm.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        selectMarketIfNeeded(app)
        app.buttons["watch.cart.open"].tap()
        XCTAssertTrue(app.staticTexts["Your cart is empty"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        openHistory(app)
        let restore = app.buttons["Restore items"]
        reveal(restore, in: app)
        restore.tap()
        app.buttons["Restore items"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        selectMarketIfNeeded(app)
        app.buttons["watch.cart.open"].tap()
        reveal(milk, in: app)
        XCTAssertTrue((milk.value as? String ?? "").contains("Quantity 2"))
        screenshot("Durable cart restored after relaunch", app: app)
    }

    func testDurableMissingAndRevokedHouseholdRetainPrivateCleanupAndHistory() {
        for scenario in ["missing", "revoked"] {
            let app = launchDurableFixture(scenario)
            if app.buttons["watch.cart.open"].waitForExistence(timeout: 3) {
                app.buttons["watch.cart.open"].tap()
            } else {
                let retained = app.buttons["Your cart"]
                reveal(retained, in: app)
                retained.tap()
            }
            let milk = app.buttons.matching(NSPredicate(format: "label == %@", "Milk")).element
            reveal(milk, in: app)
            XCTAssertFalse(app.buttons["watch.checkout.open"].isEnabled)
            milk.swipeLeft()
            app.buttons["Remove"].tap()
            XCTAssertTrue(app.staticTexts["Your cart is empty"].waitForExistence(timeout: 5))
            app.terminate()
            app.launch()
            if app.buttons["watch.cart.open"].waitForExistence(timeout: 3) {
                app.buttons["watch.cart.open"].tap()
                XCTAssertTrue(app.staticTexts["Your cart is empty"].waitForExistence(timeout: 5))
                app.navigationBars.buttons.firstMatch.tap()
            } else {
                XCTAssertFalse(app.buttons["Your cart"].exists)
            }
            openHistory(app)
            let restore = app.buttons["Restore items"]
            reveal(restore, in: app, allowDisabled: true)
            XCTAssertFalse(restore.isEnabled)
            screenshot("Retained history with " + scenario + " household", app: app)
            app.terminate()
        }
    }

    func testDurableEmptyHouseholdDiffersFromMissingSetup() {
        let setup = launchDurableFixture("setup")
        XCTAssertTrue(setup.staticTexts["Set up Shopping"].waitForExistence(timeout: 5))
        XCTAssertFalse(setup.buttons["watch.cart.open"].exists)
        setup.terminate()
        let empty = launchDurableFixture("empty")
        selectMarketIfNeeded(empty)
        XCTAssertTrue(empty.buttons["watch.cart.open"].exists)
        XCTAssertFalse(empty.staticTexts["Set up Shopping"].exists)
        XCTAssertFalse(empty.buttons["watch.checkout.open"].isEnabled)
    }

    private func launchDurableFixture(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_WATCH_DURABLE_FIXTURE"] = scenario
        app.launchEnvironment["SHOPPING_WATCH_TEST_ID"] = UUID().uuidString
        addTeardownBlock {
            app.terminate()
            app.launchEnvironment["SHOPPING_WATCH_DURABLE_FIXTURE"] = "cleanup"
            app.launch()
            XCTAssertTrue(app.staticTexts["Set up Shopping"].waitForExistence(timeout: 5))
            app.terminate()
        }
        app.launch()
        return app
    }

    private func assertReturnedToGroceries(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Item"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, file: file, line: line)
        XCTAssertTrue(app.buttons["watch.cart.open"].isHittable, file: file, line: line)
    }

    private func selectMarketIfNeeded(_ app: XCUIApplication) {
        if !app.buttons["watch.cart.open"].waitForExistence(timeout: 3) {
            let market = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Market")).element
            XCTAssertTrue(market.waitForExistence(timeout: 3))
            market.tap()
        }
        XCTAssertTrue(app.buttons["watch.cart.open"].waitForExistence(timeout: 5))
    }

    private func openHistory(_ app: XCUIApplication) {
        let switcher = storeSwitcher(in: app)
        if switcher.waitForExistence(timeout: 3) { switcher.tap() }
        let history = app.buttons["Recently cleared"]
        reveal(history, in: app)
        history.tap()
        XCTAssertTrue(app.navigationBars["Recently cleared"].waitForExistence(timeout: 3))
    }

    private func storeSwitcher(in app: XCUIApplication) -> XCUIElement {
        // Native watch toolbars repeat the identifier on nested wrappers. Scope to
        // the toolbar-owned button rather than choosing an arbitrary descendant.
        app.navigationBars.children(matching: .button).matching(identifier: "watch.store.switch").element
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_WATCH_FIXTURE"] = "populated"
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, allowOversizedRow: Bool = false, allowDisabled: Bool = false) {
        func viewport() -> (top: CGFloat, bottom: CGFloat) {
            let confirmation = app.navigationBars["Check out"]
            let navigation = confirmation.exists ? confirmation : app.navigationBars.firstMatch
            let checkout = app.buttons["watch.checkout.open"]
            let cart = app.buttons["watch.cart.open"]
            let add = app.buttons["watch.item.add"]
            // A disabled checkout still occupies space beside the enabled View cart button.
            // A presented confirmation has no footer; underlying root controls may remain in AX.
            let footerVisible = !confirmation.exists && checkout.exists
                && (checkout.isHittable || (cart.exists && cart.isHittable))
            let footerTop = footerVisible
                ? min(checkout.frame.minY, cart.exists && cart.isHittable ? cart.frame.minY : checkout.frame.minY)
                : add.exists && add.isHittable ? add.frame.minY : app.frame.maxY + 2
            return (navigation.exists ? navigation.frame.maxY : 30, footerTop - 2)
        }
        func isClear() -> Bool {
            guard element.exists && (element.isHittable || allowDisabled) else { return false }
            let bounds = viewport()
            if allowOversizedRow && element.frame.height > bounds.bottom - bounds.top {
                let visibleHeight = min(element.frame.maxY, bounds.bottom) - max(element.frame.minY, bounds.top)
                return visibleHeight >= 44 && element.frame.midY > bounds.top && element.frame.midY < bounds.bottom
            }
            return element.frame.minY >= bounds.top && element.frame.maxY <= bounds.bottom
        }
        var previousDirection: Bool?
        var needsFineAlignment = false
        for _ in 0..<24 {
            if isClear() { return }
            let bounds = viewport()
            let oversized = element.exists && allowOversizedRow && element.frame.height > bounds.bottom - bounds.top
            let isAbove = element.exists && (oversized
                ? element.frame.midY < (bounds.top + bounds.bottom) / 2
                : element.frame.minY < bounds.top)
            let distance: CGFloat
            if !element.exists { distance = .infinity }
            else if oversized { distance = abs(element.frame.midY - (bounds.top + bounds.bottom) / 2) }
            else { distance = isAbove ? bounds.top - element.frame.minY : element.frame.maxY - bounds.bottom }
            if element.exists && !oversized {
                if let previousDirection, previousDirection != isAbove { needsFineAlignment = true }
                previousDirection = isAbove
            }
            // Normal steps cross native list snap points. After overshooting a measured
            // row, align finely near its boundary without weakening the clear-frame check.
            let rotation = element.exists && !oversized
                ? (needsFineAlignment && distance <= 15 ? 0.05 : distance > 60 ? 0.6 : 0.3)
                : 0.15
            XCUIDevice.shared.rotateDigitalCrown(delta: isAbove ? -rotation : rotation)
        }
        screenshot("Unreachable element", app: app)
        XCTAssertTrue(isClear())
    }

    private func assertBottomAction(_ action: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(action.exists, file: file, line: line)
        XCTAssertGreaterThanOrEqual(action.frame.maxY, app.frame.maxY - 24, file: file, line: line)
        XCTAssertLessThanOrEqual(action.frame.maxY, app.frame.maxY, file: file, line: line)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44, file: file, line: line)
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
