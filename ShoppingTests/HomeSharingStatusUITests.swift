import XCTest

final class HomeSharingStatusUITests: XCTestCase {
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
        let groceries = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.row.")).allElementsBoundByIndex
        let savedIdentifiers = Set(groceries.map(\.identifier))
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
        XCTAssertEqual(result.label,
            "Saved work was checked on this device. iCloud activity is shown from existing observations.")
        check.tap()
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            check.isEnabled && result.exists
                && result.label == "Available observations were checked. This does not confirm delivery to another device."
                && !app.descendants(matching: .any).matching(identifier: "shopping.sharing.checking").element.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        let savedWork = app.staticTexts["shopping.sharing.section.savedWork"]
        reveal(savedWork, in: app)
        XCTAssertTrue(savedWork.label.contains("Completed saves are stored on this device."))
        XCTAssertTrue(savedWork.label.contains("do not measure CloudKit delivery"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Sharing status at accessibility XXXL"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try app.performAccessibilityAudit(for: [.dynamicType])
        let returnHome = app.buttons["shopping.sharing.returnHome"]
        reveal(returnHome, in: app, towardTop: true)
        returnHome.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Groceries"].isSelected)
        let after = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.row."))
            .allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(after, savedIdentifiers)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<12 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
            if element.exists, element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom { break }
            if element.exists && element.frame.minY < top || (!element.exists && towardTop) { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.existsOrAppears(timeout: 3), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }
}
