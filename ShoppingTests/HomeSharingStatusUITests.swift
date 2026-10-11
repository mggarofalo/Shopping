import XCTest

final class HomeSharingStatusUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Native navigation, one explicit status check, actual system text-size
    /// transitions, and returning to identical groceries remain UI-owned.
    func testStatusCheckAndReturnKeepSavedHomeAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1"
        SystemTextSize.configure(app)
        app.launch()
        let textSize = try SystemTextSize(test: self, app: app)
        try textSize.set(.accessibilityXXXL)
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        let groceries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.row."))
        XCTAssertTrue(groceries.element(boundBy: 0).existsOrAppears(timeout: 8))
        let savedIdentifiers = Set(groceries.allElementsBoundByIndex.map(\.identifier))
        XCTAssertFalse(savedIdentifiers.isEmpty)
        try textSize.set(.large)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(app.buttons["shopping.settings.sharingStatus"].exists)
        XCTAssertFalse(app.buttons["shopping.settings.recovery"].exists)
        app.buttons["shopping.home.scope"].tap()
        let home = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.home.details.")).firstMatch
        XCTAssertTrue(home.existsOrAppears(timeout: 5))
        home.tap()
        XCTAssertTrue(app.navigationBars["Preview household"].existsOrAppears(timeout: 5))
        let status = app.buttons["shopping.home.sharingStatus"]
        XCTAssertTrue(status.existsOrAppears(timeout: 3))
        reveal(status, in: app)
        XCTAssertTrue(status.isHittable)
        status.tap()
        XCTAssertTrue(app.navigationBars["Sharing status"].existsOrAppears(timeout: 5))
        let check = app.buttons["shopping.sharing.check"]
        reveal(check, in: app)
        waitForIdleCheck(check, app: app)
        let baseline = check.frame
        XCTAssertFalse(app.staticTexts["shopping.sharing.noActivity"].exists)
        XCTAssertFalse(app.buttons["shopping.sharing.details"].exists)
        XCTAssertFalse(app.buttons["shopping.sharing.returnHome"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "shopping.sharing.notice.")).count, 0)
        try textSize.set(.accessibilityXXXL)
        XCTAssertTrue(app.navigationBars["Sharing status"].exists)
        reveal(check, in: app, towardTop: true)
        XCTAssertGreaterThan(check.frame.height, baseline.height + 1)
        capture("Concise Sharing status at accessibility XXXL", app: app)
        reveal(check, in: app)
        waitForIdleCheck(check, app: app)
        XCTAssertTrue(check.isHittable)
        check.tap()
        waitForIdleCheck(check, app: app)
        XCTAssertFalse(app.staticTexts["shopping.sharing.checkResult"].exists,
            "A successful check must not add diagnostic or success paragraphs")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "shopping.sharing.notice.")).count, 0)
        reveal(check, in: app, towardTop: true)
        try textSize.set(.large)
        XCTAssertTrue(app.navigationBars["Sharing status"].exists)
        reveal(check, in: app, towardTop: true)
        XCTAssertEqual(check.frame.height, baseline.height, accuracy: 2)
        XCTAssertEqual(check.frame.width, baseline.width, accuracy: 2)
        capture("Concise Sharing status at Large restored", app: app)
        try textSize.set(.accessibilityXXXL)
        XCTAssertTrue(app.navigationBars["Sharing status"].exists)
        app.navigationBars["Sharing status"].buttons.firstMatch.tap()
        app.navigationBars["Preview household"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Groceries"].isSelected)
        XCTAssertTrue(groceries.element(boundBy: 0).existsOrAppears(timeout: 5))
        XCTAssertEqual(Set(groceries.allElementsBoundByIndex.map(\.identifier)), savedIdentifiers)
    }

    private func waitForIdleCheck(_ check: XCUIElement, app: XCUIApplication) {
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            check.isEnabled && !app.descendants(matching: .any).matching(identifier: "shopping.sharing.checking").element.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 15), .completed)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private enum Visibility { case entireControl, textBeginning, textEnd }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false,
                        visibility: Visibility = .entireControl,
                        file: StaticString = #filePath, line: UInt = #line) {
        // Half-viewport drags need more steps than full swipes to traverse this
        // screen at XXXL, especially when returning from its final paragraph.
        for step in 0..<24 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.isHittable ? app.tabBars.firstMatch.frame.minY : app.frame.maxY - 34
            let viewportHeight = bottom - top
            guard top.isFinite, bottom.isFinite, viewportHeight > 48 else { continue }
            let wholeFrame = element.exists ? element.frame : nil
            let frame = wholeFrame.map { frame in
                let visibleHeight = min(frame.height, viewportHeight / 2)
                switch visibility {
                case .entireControl: return frame
                case .textBeginning:
                    return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: visibleHeight)
                case .textEnd:
                    return CGRect(x: frame.minX, y: frame.maxY - visibleHeight, width: frame.width, height: visibleHeight)
                }
            }
            if let frame, element.isHittable, frame.minY >= top, frame.maxY <= bottom { return }
            if visibility == .textEnd, let wholeFrame, wholeFrame.minY < bottom, wholeFrame.maxY > top {
                capture("Activity scroll-through \(step + 1)", app: app)
            }
            let upper = top + viewportHeight / 4
            let lower = top + viewportHeight * 3 / 4
            let maximumTravel = lower - upper
            let minimumTravel = min(60, maximumTravel)
            let startY: CGFloat
            let endY: CGFloat
            if let frame, frame.minY < top {
                startY = upper
                endY = upper + min(max(top - frame.minY + 12, minimumTravel), maximumTravel)
            } else if let frame, frame.maxY > bottom {
                startY = lower
                endY = lower - min(max(frame.maxY - bottom + 12, minimumTravel), maximumTravel)
            } else {
                startY = towardTop ? upper : lower
                endY = towardTop ? lower : upper
            }
            // Drag only the visible list, and limit travel to the measured gap.
            // A full-screen swipe can alternate past a large-text row indefinitely.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: startY))
            let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: endY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        capture("Could not reveal intended \(visibility)", app: app)
        XCTFail("Could not reveal the intended \(visibility) between the navigation and tab bars", file: file, line: line)
    }
}
