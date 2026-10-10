import XCTest

final class HomeReplacementUITests: XCTestCase {
    func testReplaceConfirmsExactHomesAndLandsInInvitedGroceries() {
        let app = launch(mode: "prior-kept")
        let replace = app.buttons["shopping.replacement.replace"]
        XCTAssertTrue(replace.existsOrAppears(timeout: 10))
        screenshot("Starter replacement decision", app)
        replace.tap()
        let confirmation = app.alerts["Replace “My Home” with “Second home”?"]
        XCTAssertTrue(confirmation.existsOrAppears(timeout: 3))
        screenshot("Starter replacement confirmation", app)
        confirmation.buttons["Replace Home"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        openHomes(app)
        XCTAssertFalse(app.buttons["shopping.home.retainedLocal"].exists)
        XCTAssertTrue(app.buttons["Select Preview household"].exists)
        XCTAssertTrue((app.buttons["Select Second home"].value as? String)?.contains("Selected") == true)
        reveal(app.staticTexts["shopping.replacement.status"], app)
        XCTAssertEqual(app.staticTexts["shopping.replacement.status"].label, "My Home was replaced.")
        screenshot("Replacement complete in Homes", app)
    }

    func testCancelThenKeepBothNeverRemovesStarter() {
        let app = launch()
        XCTAssertTrue(app.buttons["shopping.replacement.replace"].existsOrAppears(timeout: 10))
        app.buttons["shopping.replacement.replace"].tap()
        app.alerts.buttons["Cancel"].tap()
        app.buttons["shopping.replacement.keepBoth"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        openHomes(app)
        XCTAssertTrue(app.buttons["shopping.home.retainedLocal"].existsOrAppears(timeout: 3))
        XCTAssertTrue((app.buttons["Select Second home"].value as? String)?.contains("Selected") == true)
    }

    func testNotNowPreservesStarterAndDefersOpening() {
        let app = launch()
        XCTAssertTrue(app.buttons["shopping.replacement.replace"].existsOrAppears(timeout: 10))
        app.buttons["shopping.invitation.notNow"].tap()
        XCTAssertTrue(app.buttons["shopping.home.invitationReady"].existsOrAppears(timeout: 5))
        XCTAssertFalse(app.buttons["shopping.replacement.replace"].exists)
        app.buttons["shopping.home.invitationReady"].tap()
        XCTAssertTrue(app.buttons["shopping.replacement.replace"].existsOrAppears(timeout: 10))
    }

    func testCloseDuringConfirmedActivationDoesNotCancelReplacement() {
        let app = launch(mode: "slow-activation")
        XCTAssertTrue(app.buttons["shopping.replacement.replace"].existsOrAppears(timeout: 10))
        app.buttons["shopping.replacement.replace"].tap()
        app.alerts.buttons["Replace Home"].tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.existsOrAppears(timeout: 3))
        close.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 12))
        openHomes(app)
        XCTAssertFalse(app.buttons["shopping.home.retainedLocal"].exists)
        reveal(app.staticTexts["shopping.replacement.status"], app)
        XCTAssertEqual(app.staticTexts["shopping.replacement.status"].label, "My Home was replaced.")
    }

    func testChangedStarterIsKeptWhileInvitedHomeRemainsUsable() {
        let app = launch(mode: "changed")
        XCTAssertTrue(app.buttons["shopping.replacement.replace"].existsOrAppears(timeout: 10))
        app.buttons["shopping.replacement.replace"].tap()
        app.alerts.buttons["Replace Home"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        XCTAssertTrue(app.buttons["shopping.replacement.notice"].existsOrAppears(timeout: 5))
        app.buttons["shopping.replacement.notice"].tap()
        XCTAssertTrue(app.buttons["shopping.home.retainedLocal"].existsOrAppears(timeout: 5))
        reveal(app.staticTexts["shopping.replacement.status"], app)
        XCTAssertEqual(app.staticTexts["shopping.replacement.status"].label, "My Home was kept.")
        screenshot("Changed starter kept after joining", app)
    }

    func testPopulatedStarterSkipsReplacementDecision() {
        let app = launch(mode: "populated")
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        XCTAssertFalse(app.buttons["shopping.replacement.replace"].exists)
        openHomes(app)
        XCTAssertTrue(app.buttons["shopping.home.retainedLocal"].existsOrAppears(timeout: 3))
    }

    func testInterruptedReplacementIsReviewableAfterRelaunch() {
        let app = launch(mode: "pending")
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        openHomes(app)
        let review = app.buttons["shopping.replacement.review"]
        reveal(review, app)
        XCTAssertTrue(review.isHittable)
        screenshot("Interrupted starter replacement", app)
        review.tap()
        app.alerts.buttons["Remove Starter Home"].tap()
        XCTAssertTrue(app.staticTexts["My Home was replaced."].existsOrAppears(timeout: 10))
        app.swipeDown()
        XCTAssertFalse(app.buttons["shopping.home.retainedLocal"].exists)
    }

    func testSameNamedHomesRemainDistinctAtAccessibilityTextSize() throws {
        let app = launch(mode: "same-name", systemTextSize: true)
        XCTAssertTrue(app.buttons["shopping.replacement.replace"].existsOrAppears(timeout: 10))
        let textSize = try SystemTextSize(test: self, app: app)
        try textSize.set(.accessibilityXXXL)
        let replace = app.buttons["shopping.replacement.replace"]
        reveal(replace, app)
        XCTAssertTrue(replace.isHittable)
        XCTAssertGreaterThanOrEqual(replace.frame.height, 44)
        screenshot("Same named Homes replacement at accessibility XXXL", app)
        replace.tap()
        XCTAssertTrue(app.alerts["Replace “Second home (On This iPhone)” with “Second home (Invited Home)”?"].existsOrAppears(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        try textSize.set(.large)
    }

    private func launch(mode: String = "eligible", systemTextSize: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_ACCEPTED_INVITATION"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_REPLACEMENT"] = mode
        if systemTextSize { SystemTextSize.configure(app) }
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        return app
    }

    private func openHomes(_ app: XCUIApplication) {
        let invitationClose = app.buttons["shopping.invitation.notNow"]
        XCTAssertTrue(invitationClose.waitForNonExistence(timeout: 10), "Invitation must finish dismissing before navigating")
        let settings = app.tabBars.buttons["Settings"]
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed)
        settings.tap()
        XCTAssertTrue(app.buttons["shopping.home.scope"].existsOrAppears(timeout: 5))
        app.buttons["shopping.home.scope"].tap()
        XCTAssertTrue(app.navigationBars["Homes"].existsOrAppears(timeout: 3))
    }

    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
