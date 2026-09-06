import XCTest

final class ShoppingDeviceUITests: XCTestCase {
    private let longName =
        "Organic Fair Trade Extra Large Cavendish Bananas From the Family Size Produce Display"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testLongNameAtLargestTextKeepsSeparateShoppingControlsReachable() {
        let app = launch(fixture: "longName", largestText: true)
        selectCostco(in: app)
        let row = app.buttons["Edit \(longName)"]
        reveal(row, in: app, fullyVisible: false)
        XCTAssertEqual(row.label, "Edit \(longName)")
        XCTAssertTrue((row.value as? String ?? "").contains("Buy at any store"))
        screenshot("Long grocery title at largest text", app: app)

        let increase = app.buttons["Increase quantity for \(longName)"]
        reveal(increase, in: app)
        assertTouchSize(increase)
        increase.tap()
        XCTAssertTrue(app.staticTexts["Quantity 7"].exists)
        let cart = app.buttons["Add to cart \(longName)"]
        reveal(cart, in: app)
        assertTouchSize(cart)
        screenshot("Separate quantity and cart controls at largest text", app: app)
        cart.tap()
        XCTAssertFalse(cart.exists)

        let carted = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "In cart (2)")
        ).firstMatch
        reveal(carted, in: app, towardTop: true)
        carted.tap()
        XCTAssertTrue(app.navigationBars["In cart"].waitForExistence(timeout: 3))
        let uncart = app.buttons["Remove from cart \(longName)"]
        reveal(uncart, in: app)
        assertTouchSize(uncart)
        uncart.tap()
        XCTAssertFalse(uncart.exists)
        app.navigationBars["In cart"].buttons.firstMatch.tap()
        reveal(row, in: app, fullyVisible: false)
        XCTAssertTrue(app.tabBars.buttons["Catalog"].isHittable)
        XCTAssertTrue(app.tabBars.buttons["Settings"].isHittable)
    }

    func testPrimaryScreensHaveAccessibleControls() throws {
        let app = launch(fixture: "populated")
        screenshot("Compact All groceries before accessibility audit", app: app)
        try audit(app, types: [.elementDetection, .hitRegion, .sufficientElementDescription, .trait])
        selectCostco(in: app)
        screenshot("Compact Costco before accessibility audit", app: app)
        try audit(app, types: [.elementDetection, .hitRegion, .sufficientElementDescription, .trait])

        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 3))
        screenshot("Compact catalog before accessibility audit", app: app)
        try audit(app, types: [.elementDetection, .hitRegion, .sufficientElementDescription, .trait])

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        screenshot("Compact settings before accessibility audit", app: app)
        try audit(app, types: [.elementDetection, .hitRegion, .sufficientElementDescription, .trait])
    }

    func testVisibleGroceryRowPassesFullAuditAtLargestText() throws {
        let app = launch(fixture: "populated", largestText: true)
        selectCostco(in: app)
        app.buttons["shopping.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 3))
        let urgent = app.switches["Urgent only"]
        let inner = urgent.switches.firstMatch
        (inner.exists ? inner : urgent).tap()
        app.buttons["Done"].tap()
        let row = app.buttons["Edit Granola"]
        reveal(row, in: app)
        let cell = app.cells.containing(.button, identifier: row.identifier).firstMatch
        reveal(cell, in: app)
        alignRowNearTop(cell, in: app)
        let quantity = quantity(for: row, in: app)
        XCTAssertTrue(quantity.exists)
        XCTAssertGreaterThan(quantity.frame.width, 0)
        screenshot("Fully visible grocery at largest text", app: app)
        try audit(app)
    }

    func testDefaultQuantityIsVisibleAndFilterChipsCanBeRemoved() {
        let app = launch(fixture: "populated")
        app.buttons["shopping.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 3))
        let urgent = app.switches["Urgent only"]
        let inner = urgent.switches.firstMatch
        (inner.exists ? inner : urgent).tap()
        app.buttons["Pantry"].tap()
        app.buttons["Done"].tap()
        let removeUrgent = app.buttons["Remove Urgent filter"]
        XCTAssertTrue(removeUrgent.waitForExistence(timeout: 3))
        let quantity = app.staticTexts["Quantity 1"]
        reveal(quantity, in: app)
        XCTAssertGreaterThan(quantity.frame.width, 0)
        XCTAssertGreaterThan(quantity.frame.height, 0)
        screenshot("Default text with quantity and active filters", app: app)
        removeUrgent.tap()
        XCTAssertFalse(removeUrgent.exists)
        XCTAssertTrue(app.buttons["Remove Pantry filter"].exists)
        app.buttons["Remove Pantry filter"].tap()
        XCTAssertFalse(app.buttons["Remove Pantry filter"].exists)
    }

    func testGroceryAndQuantityTextGrowWithSystemTypeSize() {
        let sizes = [
            "UICTContentSizeCategoryL",
            "UICTContentSizeCategoryXXXL",
            "UICTContentSizeCategoryAccessibilityM",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        var previousTitleHeight: CGFloat = 0
        var previousQuantityHeight: CGFloat = 0
        var previousNotesHeight: CGFloat = 0
        for size in sizes {
            let app = launch(fixture: "populated", contentSize: size)
            let title = app.staticTexts["Granola"]
            reveal(app.buttons["Edit Granola"], in: app)
            XCTAssertGreaterThan(title.frame.height, previousTitleHeight)
            previousTitleHeight = title.frame.height
            let notes = app.staticTexts["Low sugar"]
            XCTAssertGreaterThan(notes.frame.height, previousNotesHeight)
            previousNotesHeight = notes.frame.height
            let quantity = quantity(for: app.buttons["Edit Granola"], in: app)
            reveal(quantity, in: app)
            XCTAssertGreaterThan(quantity.frame.width, 0)
            XCTAssertGreaterThan(quantity.frame.height, previousQuantityHeight)
            previousQuantityHeight = quantity.frame.height
            assertTouchSize(app.buttons["Increase quantity for Granola"])
            screenshot("Grocery text sizing - \(size)", app: app)
            app.terminate()
        }
    }

    private func audit(_ app: XCUIApplication, types: XCUIAccessibilityAuditType = .all) throws {
        // Collect every issue before failing, so diagnostics aren't limited to the first result.
        var failures: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            let details = "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element")"
            failures.append("\(issue.compactDescription): \(issue.element?.label ?? "unidentified element")")
            let attachment = XCTAttachment(string: details)
            attachment.name = "Accessibility audit details"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            return true
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
    }

    private func launch(
        fixture: String, largestText: Bool = false, contentSize: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingDeviceUITest-\(UUID().uuidString).sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture
        if let size = contentSize ?? (largestText ? "UICTContentSizeCategoryAccessibilityXXXL" : nil) {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
        }
        app.launch()
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        return app
    }

    private func selectCostco(in app: XCUIApplication) {
        app.buttons["shopping.store.menu"].tap()
        app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Costco", "shopping.store.menu")
        ).firstMatch.tap()
    }

    private func reveal(
        _ element: XCUIElement, in app: XCUIApplication, fullyVisible: Bool = true, towardTop: Bool = false
    ) {
        for _ in 0..<12 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
            guard top.isFinite, bottom.isFinite, bottom - top > 48 else { continue }
            let frame = element.exists ? element.frame : .null
            let visibleHeight = min(frame.maxY, bottom) - max(frame.minY, top)
            if element.exists && element.isHittable
                && (fullyVisible ? frame.minY >= top && frame.maxY <= bottom : visibleHeight >= 44)
            {
                return
            }
            let window = app.frame
            guard window.height.isFinite, window.height > 0 else { continue }
            let movingDown = (!frame.isNull && frame.minY < top) || (frame.isNull && towardTop)
            let overflow = frame.isNull
                ? (bottom - top) * 0.4
                : (movingDown ? top - frame.minY : frame.maxY - bottom) + 12
            let distance = max(24, min(overflow, (bottom - top) * 0.4)) / window.height
            let startY: CGFloat = movingDown ? 0.35 : 0.65
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            let end = app.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5, dy: startY + (movingDown ? distance : -distance)
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not reveal the requested element between navigation and tab bars")
    }

    private func alignRowNearTop(_ cell: XCUIElement, in app: XCUIApplication) {
        // Keep the entire audited row visible and its preceding section header out
        // of the navigation-bar overlay, where the audit can sample obscured text.
        var previousTop: CGFloat?
        for _ in 0..<6 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
            let frame = cell.frame
            let target = top + 24
            let offset = frame.minY - target
            let fullyVisible = frame.minY >= top && frame.maxY <= bottom
            if fullyVisible && abs(offset) <= 12 { return }
            // A larger screen can reach the natural end of the list first.
            // The full audit still runs; only the target's complete visibility is required.
            if let previousTop, fullyVisible && abs(frame.minY - previousTop) < 1 { return }
            previousTop = frame.minY
            let viewport = bottom - top
            guard offset.isFinite, viewport.isFinite, viewport > 48 else { continue }
            let distance = min(abs(offset), viewport * 0.4)
            let startY = top + viewport * (offset > 0 ? 0.7 : 0.3)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: startY))
            let end = origin.withOffset(CGVector(
                dx: app.frame.midX, dy: startY + (offset > 0 ? -distance : distance)
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not position the complete grocery row clear of the navigation overlay")
    }

    private func quantity(for row: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let prefix = "shopping.grocery.row."
        XCTAssertTrue(row.identifier.hasPrefix(prefix))
        let id = String(row.identifier.dropFirst(prefix.count))
        return app.staticTexts["shopping.checklist.quantity.value.\(id)"]
    }

    private func assertTouchSize(_ element: XCUIElement) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44 - 0.01)
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
