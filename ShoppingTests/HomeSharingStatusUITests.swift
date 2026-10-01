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
        SystemTextSizeSettings.configure(app)
        app.launch()
        let textSize = try SystemTextSizeSettings(test: self, app: app)
        try textSize.set(.accessibilityXXXL)
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        let groceries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.row."))
        // Navigation appears before the saved grocery projection finishes loading.
        XCTAssertTrue(groceries.element(boundBy: 0).existsOrAppears(timeout: 8))
        let savedIdentifiers = Set(groceries.allElementsBoundByIndex.map(\.identifier))
        XCTAssertFalse(savedIdentifiers.isEmpty, "The workflow must begin with saved groceries")
        try textSize.set(.large)
        XCTAssertTrue(app.navigationBars["Groceries"].exists)
        app.tabBars.buttons["Settings"].tap()
        let status = app.buttons["shopping.settings.sharingStatus"]
        reveal(status, in: app)
        status.tap()
        XCTAssertTrue(app.navigationBars["Sharing status"].existsOrAppears(timeout: 5))
        let summary = app.staticTexts["shopping.sharing.summary"]
        XCTAssertTrue(summary.existsOrAppears(timeout: 5))
        XCTAssertFalse(summary.label.contains("up to date"))
        let summaryCopy = summary.label
        reveal(summary, in: app, towardTop: true)
        let baselineSummary = summary.frame
        XCTAssertFalse(app.buttons["shopping.sharing.returnHome"].exists)
        XCTAssertFalse(app.staticTexts["shopping.sharing.section.account"].exists)
        openDetails(app)
        let home = app.staticTexts["shopping.sharing.section.home"]
        reveal(home, in: app, visibility: .textBeginning)
        let homeCopy = home.label
        let savedWork = app.staticTexts["shopping.sharing.section.savedWork"]
        reveal(savedWork, in: app, visibility: .textBeginning)
        let savedCopy = savedWork.label
        XCTAssertTrue(savedCopy.contains("Completed saves are stored on this device."))
        XCTAssertTrue(savedCopy.contains("do not measure CloudKit delivery"))
        let baselineSavedWork = captureParagraph(savedWork, expected: savedCopy, phase: "Large", app: app)
        closeDetails(app)
        reveal(summary, in: app, towardTop: true)
        try textSize.set(.accessibilityXXXL)
        // Check the retained destination and visible top content before scrolling.
        // Deep List rows may be virtualized by the size change.
        XCTAssertTrue(app.navigationBars["Sharing status"].exists)
        XCTAssertTrue(summary.exists)
        XCTAssertEqual(summary.label, summaryCopy)
        reveal(summary, in: app, towardTop: true)
        XCTAssertGreaterThan(summary.frame.height, baselineSummary.height + 1)
        capture("Sharing status overview at accessibility XXXL", app: app)
        let check = app.buttons["shopping.sharing.check"]
        reveal(check, in: app, towardTop: true)
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 12), .completed)
        let result = app.staticTexts["shopping.sharing.checkResult"]
        // Read the result, then bring the explicit action back onscreen.
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
        openDetails(app)
        reveal(home, in: app, visibility: .textBeginning)
        XCTAssertEqual(home.label, homeCopy)
        let enlargedSavedWork = captureParagraph(savedWork, expected: savedCopy, phase: "accessibility XXXL", app: app)
        XCTAssertGreaterThan(enlargedSavedWork.height, baselineSavedWork.height + 1)
        reveal(home, in: app, towardTop: true, visibility: .textBeginning)
        try textSize.set(.large)
        XCTAssertTrue(app.navigationBars["Sharing details"].exists)
        reveal(home, in: app, visibility: .textBeginning)
        XCTAssertEqual(home.label, homeCopy)
        let returnedSavedWork = captureParagraph(savedWork, expected: savedCopy, phase: "Large restored", app: app)
        XCTAssertEqual(returnedSavedWork.height, baselineSavedWork.height, accuracy: 2)
        XCTAssertEqual(returnedSavedWork.width, baselineSavedWork.width, accuracy: 2)
        closeDetails(app)
        reveal(summary, in: app, towardTop: true)
        XCTAssertEqual(summary.label, summaryCopy)
        XCTAssertEqual(summary.frame.height, baselineSummary.height, accuracy: 2)
        XCTAssertEqual(summary.frame.width, baselineSummary.width, accuracy: 2)
        // Return through the existing tab at the same system category as launch.
        reveal(summary, in: app, towardTop: true)
        try textSize.set(.accessibilityXXXL)
        XCTAssertTrue(app.navigationBars["Sharing status"].exists)
        XCTAssertTrue(summary.exists)
        XCTAssertEqual(summary.label, summaryCopy)
        XCTAssertFalse(app.buttons["shopping.sharing.returnHome"].exists)
        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Groceries"].isSelected)
        XCTAssertTrue(groceries.element(boundBy: 0).existsOrAppears(timeout: 5))
        let after = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.row."))
            .allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(after, savedIdentifiers)
    }

    private func openDetails(_ app: XCUIApplication) {
        let details = app.buttons["shopping.sharing.details"]
        reveal(details, in: app)
        details.tap()
        XCTAssertTrue(app.navigationBars["Sharing details"].existsOrAppears(timeout: 3))
        XCTAssertTrue(details.waitForNonExistence(timeout: 3))
    }

    private func closeDetails(_ app: XCUIApplication) {
        let back = app.navigationBars["Sharing details"].buttons["Sharing status"]
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.navigationBars["Sharing status"].existsOrAppears(timeout: 3))
        XCTAssertTrue(app.navigationBars["Sharing details"].waitForNonExistence(timeout: 3))
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Screenshots cover the actual paragraph from its beginning to its end,
    /// with measured overlap. A full accessibility label or height alone is not
    /// evidence that the user can read every line.
    private func captureParagraph(_ element: XCUIElement, expected: String, phase: String,
                                  app: XCUIApplication) -> CGRect {
        reveal(element, in: app, visibility: .textBeginning)
        var covered: CGFloat = 0
        let initial = element.frame
        for step in 0..<24 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
            let frame = element.frame
            XCTAssertEqual(frame.height, initial.height, accuracy: 1, "Paragraph height must remain stable while measuring coverage")
            XCTAssertEqual(frame.width, initial.width, accuracy: 1, "Paragraph width must remain stable while measuring coverage")
            XCTAssertEqual(element.label, expected)
            XCTAssertTrue(element.isHittable)
            XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX)
            let start = max(0, top - frame.minY)
            let end = min(frame.height, bottom - frame.minY)
            XCTAssertGreaterThan(end, start)
            if step == 0 { XCTAssertLessThanOrEqual(start, 1, "The first screenshot must include the paragraph beginning") }
            else {
                XCTAssertLessThan(start, covered - 12, "Successive screenshots must overlap readable text")
                XCTAssertGreaterThan(end, covered + 1, "Scrolling must expose new paragraph content")
            }
            capture("Saved work \(phase) segment \(step + 1)", app: app)
            covered = end
            if frame.maxY <= bottom {
                XCTAssertGreaterThanOrEqual(covered, frame.height - 1, "The final screenshot must include the paragraph end")
                return initial
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.midX, dy: top + (bottom - top) * 0.75))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: top + (bottom - top) * 0.35)))
        }
        XCTFail("Could not read the complete saved-work paragraph in \(phase)")
        return initial
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
        capture("Could not reveal intended \(visibility)", app: app)
        XCTFail("Could not reveal the intended \(visibility) between the navigation and tab bars", file: file, line: line)
    }
}
