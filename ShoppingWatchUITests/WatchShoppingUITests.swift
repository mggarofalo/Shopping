import XCTest

final class WatchShoppingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testNormalLaunchShowsSetupWithoutDemoGroceries() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Set up Shopping"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["watch.store.switch"].exists)
        screenshot("Watch normal launch setup", app: app)
    }

    func testStoreTitleSwitchAndNativeSwipeCart() {
        let app = launchFixture()
        let switcher = storeSwitcher(in: app)
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertTrue(switcher.isHittable)
        XCTAssertLessThanOrEqual(switcher.frame.maxX, app.frame.maxX - 40)
        screenshot("Watch compact grocery root", app: app)
        switcher.tap()
        let costco = app.buttons["watch.store.10000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(costco.waitForExistence(timeout: 3))
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

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, allowOversizedRow: Bool = false) {
        func viewport() -> (top: CGFloat, bottom: CGFloat) {
            let navigation = app.navigationBars.firstMatch
            let checkout = app.buttons["watch.checkout.open"]
            let cart = app.buttons["watch.cart.open"]
            // A disabled checkout still occupies space beside the enabled View cart button.
            let footerVisible = checkout.exists && (checkout.isHittable || (cart.exists && cart.isHittable))
            return (navigation.exists ? navigation.frame.maxY : 30,
                    footerVisible ? checkout.frame.minY - 2 : app.frame.maxY)
        }
        func isClear() -> Bool {
            guard element.exists && element.isHittable else { return false }
            let bounds = viewport()
            if allowOversizedRow && element.frame.height > bounds.bottom - bounds.top {
                let visibleHeight = min(element.frame.maxY, bounds.bottom) - max(element.frame.minY, bounds.top)
                return visibleHeight >= 44 && element.frame.midY > bounds.top && element.frame.midY < bounds.bottom
            }
            return element.frame.minY >= bounds.top && element.frame.maxY <= bounds.bottom
        }
        for _ in 0..<24 {
            if isClear() { return }
            let bounds = viewport()
            let oversized = element.exists && allowOversizedRow && element.frame.height > bounds.bottom - bounds.top
            let isAbove = element.exists && (oversized
                ? element.frame.midY < (bounds.top + bounds.bottom) / 2
                : element.frame.minY < bounds.top)
            XCUIDevice.shared.rotateDigitalCrown(delta: isAbove ? -0.15 : 0.15)
        }
        screenshot("Unreachable element", app: app)
        XCTAssertTrue(isClear())
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
