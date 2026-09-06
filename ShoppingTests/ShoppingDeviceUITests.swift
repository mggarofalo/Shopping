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
        screenshot("Quantity control and swipe affordance at largest text", app: app)
        revealSwipeAction("In cart", for: row, in: app)
        app.buttons["In cart"].tap()
        XCTAssertFalse(row.exists)

        let carted = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "In cart (2)")
        ).firstMatch
        reveal(carted, in: app, towardTop: true)
        carted.tap()
        XCTAssertTrue(app.navigationBars["In cart"].waitForExistence(timeout: 3))
        let cartedRow = app.buttons["Edit \(longName)"]
        reveal(cartedRow, in: app, fullyVisible: false)
        revealSwipeAction("Remove from cart", for: cartedRow, in: app)
        app.buttons["Remove from cart"].tap()
        XCTAssertFalse(cartedRow.exists)
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

    func testCatalogRowSupportingTextContrast() throws {
        let app = launch(fixture: "populated")
        app.tabBars.buttons["Catalog"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Granola\n")
        XCTAssertTrue(app.staticTexts["Granola"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.catalog.item."))
        XCTAssertEqual(rows.count, 1)
        let row = rows.firstMatch
        XCTAssertTrue(row.isHittable)
        XCTAssertGreaterThanOrEqual(row.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(row.frame.maxY, app.tabBars.firstMatch.frame.minY)
        screenshot("Catalog supporting text contrast", app: app)
        // This regression measures the catalog row's title and small captions.
        // Navigation and filter controls are outside its scope; retain their
        // reports as diagnostics alongside the separate primary-control audits.
        try app.performAccessibilityAudit(for: .contrast) { issue in
            self.attachAudit(issue, phase: "Catalog row contrast")
            guard let element = issue.element else { return false }
            return !self.contains(element, in: row)
        }
    }

    func testVisibleGroceryRowAccessibilityAtLargestText() {
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
        screenshot("Fully visible grocery at largest text", app: app)
        let navigationBar = app.navigationBars["Groceries"]
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(row.isHittable)
        XCTAssertGreaterThanOrEqual(cell.frame.minY, navigationBar.frame.maxY)
        XCTAssertLessThanOrEqual(cell.frame.maxY, tabBar.frame.minY)
        XCTAssertEqual(row.label, "Edit Granola")
        let value = row.value as? String ?? ""
        XCTAssertTrue(value.contains("Urgent"))
        XCTAssertTrue(value.contains("Only buy at Costco"))
        XCTAssertTrue(value.contains("Low sugar"))
        let header = app.staticTexts["Must buy here · Pantry"]
        XCTAssertTrue(header.exists)
        XCTAssertTrue(header.isHittable)
    }

    func testExplicitQuantityIsVisibleAndFilterChipsCanBeRemoved() {
        let app = launch(fixture: "populated")
        selectCostco(in: app)
        let granola = app.buttons["Edit Granola"]
        reveal(granola, in: app)
        granola.tap()
        let addQuantity = app.buttons["shopping.grocery.quantity.add"]
        XCTAssertTrue(addQuantity.waitForExistence(timeout: 2))
        addQuantity.tap()
        XCTAssertEqual(app.steppers["shopping.grocery.quantity"].value as? String, "1")
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 2))

        app.buttons["shopping.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 3))
        let urgent = app.switches["Urgent only"]
        let inner = urgent.switches.firstMatch
        (inner.exists ? inner : urgent).tap()
        app.buttons["Pantry"].tap()
        app.buttons["Done"].tap()
        let removeUrgent = app.buttons["Remove Urgent filter"]
        XCTAssertTrue(removeUrgent.waitForExistence(timeout: 3))
        let clearStore = app.buttons["shopping.store.clear"]
        reveal(clearStore, in: app, towardTop: true)
        XCTAssertEqual(clearStore.label, "Clear selected store")
        clearStore.tap()
        XCTAssertFalse(clearStore.exists)
        XCTAssertTrue(app.buttons["shopping.store.all"].isSelected)
        XCTAssertTrue(removeUrgent.exists)
        XCTAssertTrue(app.buttons["Remove Pantry filter"].exists)
        let quantity = app.staticTexts["Quantity 1"]
        reveal(quantity, in: app)
        XCTAssertGreaterThan(quantity.frame.width, 0)
        XCTAssertGreaterThan(quantity.frame.height, 0)
        screenshot("Explicit quantity with active filters", app: app)
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
            let bananas = app.buttons["Edit Bananas"]
            reveal(bananas, in: app)
            let quantity = quantity(for: bananas, in: app)
            reveal(quantity, in: app)
            XCTAssertGreaterThan(quantity.frame.width, 0)
            XCTAssertGreaterThan(quantity.frame.height, previousQuantityHeight)
            previousQuantityHeight = quantity.frame.height
            assertTouchSize(app.buttons["Increase quantity for Bananas"])
            screenshot("Grocery text sizing - \(size)", app: app)
            app.terminate()
        }
    }

    private struct EdgeAuditCandidate: Equatable {
        let type: XCUIAccessibilityAuditType
        let identifier: String
        let label: String
    }

    private func audit(
        _ app: XCUIApplication,
        types: XCUIAccessibilityAuditType = .all,
        groceryViewport: Bool = false
    ) throws {
        var failures: [String] = []
        var candidates: [EdgeAuditCandidate] = []
        try app.performAccessibilityAudit(for: types) { issue in
            self.attachAudit(issue, phase: "Initial audit")
            // Static text has no tap target. Xcode's hit-region audit can still
            // report compact headers and quantity readouts as if they were controls.
            if issue.auditType == .hitRegion, issue.element?.elementType == .staticText {
                return true
            }
            // Scrolling can place list text under the opaque navigation bar.
            // Remeasure identified edge findings with that text fully visible.
            if groceryViewport, let candidate = self.edgeCandidate(issue, in: app) {
                if !candidates.contains(candidate) { candidates.append(candidate) }
            } else {
                failures.append("\(issue.compactDescription): \(issue.element?.label ?? "unidentified element")")
            }
            return true
        }
        var candidateIndex = 0
        while candidateIndex < candidates.count {
            guard candidates.count <= 20 else {
                XCTFail("Accessibility remeasurement did not converge")
                return
            }
            let candidate = candidates[candidateIndex]
            candidateIndex += 1
            let matches = app.staticTexts.matching(NSPredicate(
                format: "identifier == %@ AND label == %@", candidate.identifier, candidate.label
            ))
            guard matches.count == 1 else {
                XCTFail("Cannot uniquely remeasure \(candidate.label)")
                return
            }
            let element = matches.firstMatch
            let cells = containingCells(candidate, in: app)
            guard cells.count == 1 else {
                XCTFail("Cannot uniquely reveal the containing row for \(candidate.label)")
                return
            }
            // Reveal the whole containing row so that measuring one scope label
            // does not leave its neighboring label partly under the navigation bar.
            reveal(cells.firstMatch, in: app, towardTop: true)
            reveal(element, in: app, towardTop: true)
            XCTAssertEqual(matches.count, 1)
            XCTAssertTrue(element.isHittable)
            XCTAssertTrue(usable(element.frame))
            XCTAssertGreaterThanOrEqual(cells.firstMatch.frame.minY, app.navigationBars["Groceries"].frame.maxY)
            XCTAssertLessThanOrEqual(cells.firstMatch.frame.maxY, app.tabBars.firstMatch.frame.minY)
            XCTAssertGreaterThanOrEqual(element.frame.minY, app.navigationBars["Groceries"].frame.maxY)
            XCTAssertLessThanOrEqual(element.frame.maxY, app.tabBars.firstMatch.frame.minY)
            screenshot("Remeasuring \(candidate.label) fully visible", app: app)
            try app.performAccessibilityAudit(for: candidate.type) { issue in
                self.attachAudit(issue, phase: "Remeasuring \(candidate.label)")
                // Moving one row into view can move another behind system chrome.
                // Every newly reported edge candidate must pass its own remeasurement.
                if let edge = self.edgeCandidate(issue, in: app), edge != candidate {
                    if !candidates.contains(edge) { candidates.append(edge) }
                    return true
                }
                failures.append("\(issue.compactDescription): \(issue.element?.label ?? "unidentified element")")
                return true
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
    }

    private func attachAudit(_ issue: XCUIAccessibilityAuditIssue, phase: String) {
        let details = "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element")"
        let attachment = XCTAttachment(string: details)
        attachment.name = "\(phase): accessibility audit details"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func edgeCandidate(
        _ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication
    ) -> EdgeAuditCandidate? {
        guard issue.auditType == .contrast || issue.auditType == .textClipped,
            let element = issue.element, element.elementType == .staticText, element.exists
        else { return nil }
        let bar = app.navigationBars["Groceries"]
        let tabBar = app.tabBars.firstMatch
        let candidate = EdgeAuditCandidate(
            type: issue.auditType, identifier: element.identifier, label: element.label
        )
        let cells = containingCells(candidate, in: app)
        guard bar.exists, tabBar.exists, usable(bar.frame), usable(tabBar.frame), usable(element.frame),
            !contains(element, in: bar), !contains(element, in: tabBar),
            contains(element, in: app.collectionViews.firstMatch), cells.count == 1,
            usable(cells.firstMatch.frame)
        else { return nil }
        let frame = cells.firstMatch.frame
        guard frame.minY < bar.frame.maxY || frame.maxY > tabBar.frame.minY else { return nil }
        return candidate
    }

    private func containingCells(_ candidate: EdgeAuditCandidate, in app: XCUIApplication) -> XCUIElementQuery {
        app.cells.containing(NSPredicate(
            format: "elementType == %d AND identifier == %@ AND label == %@",
            XCUIElement.ElementType.staticText.rawValue, candidate.identifier, candidate.label
        ))
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
        var diagnostics: [String] = []
        var previousDirection: Bool?
        var preciseAlignment = false
        for _ in 0..<12 {
            let window = app.frame
            let navigationBar = app.navigationBars.firstMatch
            let navigationFrame = navigationBar.frame
            let tabBarFrame = app.tabBars.firstMatch.frame
            guard usable(window), usable(navigationFrame), usable(tabBarFrame) else { continue }
            let targetIsInNavigationBar = contains(element, in: navigationBar)
            let top = targetIsInNavigationBar ? window.minY : navigationFrame.maxY
            let bottom = tabBarFrame.minY
            guard bottom - top > 48 else { continue }
            let frame = element.exists ? element.frame : .null
            let targetExists = element.exists
            diagnostics.append("Target \(targetExists ? element.label : "missing"): \(frame); hittable \(targetExists && element.isHittable); viewport \(top)...\(bottom)")
            let visibleHeight = min(frame.maxY, bottom) - max(frame.minY, top)
            if element.exists && element.isHittable
                && (fullyVisible ? frame.minY >= top && frame.maxY <= bottom : visibleHeight >= 44)
            {
                return
            }
            let movingDown = (!frame.isNull && frame.minY < top) || (frame.isNull && towardTop)
            if let previousDirection, movingDown != previousDirection {
                preciseAlignment = true
            }
            previousDirection = movingDown
            let overflow = frame.isNull
                ? (bottom - top) * 0.4
                : (movingDown ? top - frame.minY : frame.maxY - bottom) + 12
            let viewport = bottom - top
            let maximumTravel = viewport / 2
            let distance = min(max(overflow, min(60, maximumTravel)), maximumTravel)
            let startY = top + viewport * (movingDown ? 0.25 : 0.75)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: window.midX, dy: startY))
            let end = origin.withOffset(CGVector(
                dx: window.midX, dy: startY + (movingDown ? distance : -distance)
            ))
            // A normal pan engages the List/search-bar interaction. Once a pan
            // overshoots, remove momentum so a tall cell can fit the viewport
            // without bouncing repeatedly between its two edges.
            if preciseAlignment {
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            } else {
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        let attachment = XCTAttachment(string: diagnostics.joined(separator: "\n") + "\n" + app.debugDescription)
        attachment.name = "Failed reveal geometry"
        attachment.lifetime = .keepAlways
        add(attachment)
        screenshot("Failed reveal viewport", app: app)
        XCTFail("Could not reveal the requested element between navigation and tab bars")
    }

    private func contains(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        guard element.exists, usable(element.frame), container.exists else { return false }
        return container.descendants(matching: element.elementType).matching(NSPredicate(
            format: "identifier == %@ AND label == %@", element.identifier, element.label
        )).firstMatch.exists
    }

    private func usable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty
            && frame.minX.isFinite && frame.minY.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite
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
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTFail("Could not position the complete grocery row clear of the navigation overlay")
    }

    private func revealSwipeAction(_ label: String, for row: XCUIElement, in app: XCUIApplication) {
        let action = app.buttons[label]
        reveal(row, in: app, fullyVisible: false)
        for _ in 0..<3 {
            if action.exists && action.isHittable {
                return
            }
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
            if action.waitForExistence(timeout: 1), action.isHittable {
                return
            }
        }
        XCTFail("Could not reveal the \(label) swipe action")
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
