import XCTest

final class HomeDetailsUITests: XCTestCase {
    func testOwnerRemovalConfirmationCanCancelThenRemoveOnlyContributor() {
        let app = launch(role: "owner")
        openHomeDetails(app)
        let remove = app.buttons["shopping.home.remove.fixture-long-name"]
        reveal(remove, in: app)
        remove.tap()
        let confirm = app.buttons["shopping.home.confirmRemoval"]
        XCTAssertTrue(confirm.existsOrAppears(timeout: 3))
        XCTAssertTrue(app.staticTexts["Alexandra Penelope Montgomery-Wellington"].exists)
        app.navigationBars["Change sharing access"].buttons["Cancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertTrue(remove.existsOrAppears(timeout: 3))
        remove.tap()
        XCTAssertTrue(confirm.existsOrAppears(timeout: 3))
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        let counts = app.staticTexts["shopping.home.memberCounts"]
        reveal(counts, in: app, towardTop: true)
        XCTAssertEqual(counts.label, "0 other accepted members · 0 pending invitations")
        XCTAssertTrue(app.staticTexts["Morgan · You"].exists)
        XCTAssertFalse(app.buttons["shopping.home.remove.fixture-owner"].exists)
        XCTAssertFalse(remove.exists)
        let invite = app.buttons["shopping.home.invite"]
        reveal(invite, in: app)
        XCTAssertTrue(invite.isEnabled)
    }

    func testOwnerDisclosureCancelAndShareCancellationKeepPendingInvitationAvailableToResend() {
        let app = launch(role: "owner")
        openHomeDetails(app)
        XCTAssertEqual(app.staticTexts["shopping.home.memberCounts"].label,
            "1 other accepted members · 0 pending invitations")
        XCTAssertTrue(app.staticTexts["Morgan · You"].existsOrAppears(timeout: 3))
        let invite = app.buttons["shopping.home.invite"]
        reveal(invite, in: app)
        invite.tap()
        let confirm = app.buttons["shopping.home.confirmInvite"]
        XCTAssertTrue(confirm.existsOrAppears(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Personal cart contents and purchase history stay private.")).element.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Anyone you send or forward this link to can claim its one invitation")).element.exists)
        app.navigationBars["Invite contributor"].buttons["Cancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        let counts = app.staticTexts["shopping.home.memberCounts"]
        reveal(counts, in: app, towardTop: true)
        XCTAssertEqual(counts.label, "1 other accepted members · 0 pending invitations")
        reveal(invite, in: app)
        invite.tap()
        reveal(confirm, in: app)
        confirm.tap()
        dismissSystemShareSheet(app)
        reveal(counts, in: app, towardTop: true)
        XCTAssertEqual(counts.label, "1 other accepted members · 1 pending invitations")
        let resend = app.buttons["shopping.home.resend.fixture-invitation-1"]
        reveal(resend, in: app)
        XCTAssertTrue(app.staticTexts["Invitation pending"].existsOrAppears(timeout: 3))
        resend.tap()
        dismissSystemShareSheet(app)
        reveal(counts, in: app, towardTop: true)
        XCTAssertEqual(counts.label, "1 other accepted members · 1 pending invitations")
    }

    func testContributorCanRenameHomeButCannotInviteAndNameSurvivesRelaunch() {
        let app = launch(role: "contributor")
        openHomeDetails(app)
        XCTAssertTrue(app.staticTexts["Taylor · You"].existsOrAppears(timeout: 3))
        XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
        XCTAssertFalse(app.buttons["shopping.home.stopSharing"].exists)
        XCTAssertFalse(app.buttons["shopping.home.remove.fixture-long-name"].exists)
        let rename = app.buttons["shopping.home.rename"]
        reveal(rename, in: app, towardTop: true)
        XCTAssertTrue(rename.isEnabled)
        rename.tap()
        let name = app.textFields["shopping.home.nameEditor"]
        XCTAssertTrue(name.existsOrAppears(timeout: 3))
        name.tap()
        let previous = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + "Shared kitchen")
        XCTAssertEqual(name.value as? String, "Shared kitchen")
        app.buttons["Save home name"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        let saved = app.staticTexts["shopping.home.name"]
        XCTAssertTrue(saved.existsOrAppears(timeout: 5))
        XCTAssertEqual(saved.label, "Shared kitchen")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        openHomeDetails(app)
        XCTAssertEqual(saved.label, "Shared kitchen")
        XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
    }

    func testRestrictedMembershipAndLongNamesRemainReadableAtAccessibilityTextSize() throws {
        let app = launch(role: "restricted", largestText: true)
        openHomeDetails(app)
        let rename = app.buttons["shopping.home.rename"]
        reveal(rename, in: app)
        XCTAssertFalse(rename.isEnabled)
        XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
        let current = app.staticTexts["Taylor · You"]
        reveal(current, in: app)
        let longName = app.staticTexts["Alexandra Penelope Montgomery-Wellington"]
        reveal(longName, in: app)
        XCTAssertGreaterThan(longName.frame.height, 44, "The full member name should wrap at accessibility text sizes.")
        try app.performAccessibilityAudit(for: [.dynamicType])
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home members at accessibility XXXL"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let refresh = app.buttons["Check members again"]
        reveal(refresh, in: app)
        XCTAssertTrue(refresh.isEnabled)
        refresh.tap()
        XCTAssertFalse(app.staticTexts["shopping.home.error"].exists)
        XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
    }

    private func launch(role: String, largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_HOME_MEMBERS"] = role
        if largestText {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func openHomeDetails(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        app.tabBars.buttons["Settings"].tap()
        let details = app.buttons["shopping.settings.homeDetails"]
        reveal(details, in: app)
        details.tap()
        XCTAssertTrue(app.navigationBars["Home details"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.staticTexts["shopping.home.memberCounts"].existsOrAppears(timeout: 5))
    }

    private func dismissSystemShareSheet(_ app: XCUIApplication) {
        // Inspect this native control on each supported simulator; never choose a
        // recipient or activity. Closing the sheet must retain the pending member.
        let close = app.buttons["Close"]
        XCTAssertTrue(close.existsOrAppears(timeout: 5))
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY - 20
            if element.exists, element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom { break }
            if element.exists && element.frame.minY < top || (!element.exists && towardTop) { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.existsOrAppears(timeout: 3), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }
}
