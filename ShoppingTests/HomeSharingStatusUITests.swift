import XCTest

final class HomeSharingStatusUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The fast layer owns status precedence, scoped counts and bounded refresh.
    /// This workflow owns their accessible screen, explicit check and return to
    /// the same saved groceries without a store reset or navigation side effect.
    func testStatusCheckAndReturnKeepSavedHomeAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1"
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        let groceries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.row."))
        // Navigation appears before the saved grocery projection finishes loading.
        XCTAssertTrue(groceries.element(boundBy: 0).existsOrAppears(timeout: 8))
        let savedIdentifiers = Set(groceries.allElementsBoundByIndex.map(\.identifier))
        XCTAssertFalse(savedIdentifiers.isEmpty, "The workflow must begin with saved groceries")
        app.tabBars.buttons["Settings"].tap()
        let status = app.buttons["shopping.settings.sharingStatus"]
        reveal(status, in: app)
        status.tap()
        XCTAssertTrue(app.navigationBars["Sharing status"].existsOrAppears(timeout: 5))
        let summary = app.staticTexts["shopping.sharing.summary"]
        XCTAssertTrue(summary.existsOrAppears(timeout: 5))
        XCTAssertFalse(summary.label.contains("up to date"))
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "Sharing status overview at accessibility XXXL"
        overview.lifetime = .keepAlways
        add(overview)
        let check = app.buttons["shopping.sharing.check"]
        reveal(check, in: app)
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 12), .completed)
        let result = app.staticTexts["shopping.sharing.checkResult"]
        // At XXXL the result follows two tall action rows and may not yet be
        // materialized by List. Read it, then bring the single action back onscreen.
        reveal(result, in: app, visibility: .textBeginning)
        XCTAssertEqual(result.label,
            "Saved work was checked on this device. iCloud activity is shown from existing observations.")
        reveal(check, in: app, towardTop: true)
        check.tap()
        reveal(result, in: app, visibility: .textBeginning)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            result.exists
                && result.label == "Available observations were checked. This does not confirm delivery to another device."
                && !app.descendants(matching: .any).matching(identifier: "shopping.sharing.checking").element.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        XCTAssertEqual(result.label,
            "Available observations were checked. This does not confirm delivery to another device.")
        reveal(check, in: app, towardTop: true)
        XCTAssertTrue(check.isEnabled)
        let savedWork = app.staticTexts["shopping.sharing.section.savedWork"]
        reveal(savedWork, in: app, visibility: .textBeginning)
        XCTAssertTrue(savedWork.label.contains("Completed saves are stored on this device."))
        XCTAssertTrue(savedWork.label.contains("do not measure CloudKit delivery"))
        capture("Saved work beginning at accessibility XXXL", app: app)
        try auditDynamicType(in: app, phase: "Saved work beginning")
        reveal(savedWork, in: app, visibility: .textEnd)
        capture("Saved work ending at accessibility XXXL", app: app)
        try auditDynamicType(in: app, phase: "Saved work ending")
        let returnHome = app.buttons["shopping.sharing.returnHome"]
        reveal(returnHome, in: app, towardTop: true)
        returnHome.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Groceries"].isSelected)
        XCTAssertTrue(groceries.element(boundBy: 0).existsOrAppears(timeout: 5))
        let after = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.row."))
            .allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(after, savedIdentifiers)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func auditDynamicType(in app: XCUIApplication, phase: String) throws {
        try app.performAccessibilityAudit(for: [.dynamicType]) { issue in
            let details = "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element")"
            let attachment = XCTAttachment(string: details)
            attachment.name = "\(phase): Dynamic Type audit details"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            return false
        }
    }

    private enum Visibility { case entireControl, textBeginning, textEnd }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false,
                        visibility: Visibility = .entireControl,
                        file: StaticString = #filePath, line: UInt = #line) {
        // Half-viewport drags need more steps than full swipes to traverse this
        // screen at XXXL, especially when returning from its final paragraph.
        for step in 0..<24 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
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
                capture("Saved work scroll-through \(step + 1)", app: app)
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
        capture("Could not reveal \(element.identifier)", app: app)
        XCTFail("Could not reveal \(visibility) of \(element.identifier) between the navigation and tab bars", file: file, line: line)
    }
}
