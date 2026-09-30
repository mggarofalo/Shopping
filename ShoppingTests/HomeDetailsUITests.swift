import XCTest

final class HomeDetailsUITests: XCTestCase {
    func testSubmittedLeaveWithMissingRootKeepsStatusReachableThroughChooseHome() {
        let app = launch(role: "contributor", rootGoneLeave: true)
        openHomeDetails(app)
        let homeName = app.staticTexts["shopping.home.name"].label
        let leave = app.buttons["shopping.home.leave"]
        reveal(leave, in: app)
        leave.tap()
        let confirm = app.buttons["shopping.home.confirmLeave"]
        reveal(confirm, in: app)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        let chooseHome = app.buttons["Choose a home"]
        XCTAssertTrue(chooseHome.existsOrAppears(timeout: 8))
        XCTAssertTrue(chooseHome.isHittable)
        XCTAssertTrue(app.staticTexts["Waiting for your household"].exists)
        XCTAssertTrue(app.staticTexts["Leaving a home is still being verified. Open Homes to check its status. Your personal cart and history remain saved."].exists)
        chooseHome.tap()
        XCTAssertTrue(app.navigationBars["Homes"].existsOrAppears(timeout: 5))
        XCTAssertFalse(app.buttons["shopping.home.choice." + homeName].exists,
            "The deleted shared root must not remain available as a home choice")
        let retainedStatus = app.staticTexts.matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "shopping.home.leaveStatus.")).element
        reveal(retainedStatus, in: app)
        XCTAssertEqual(retainedStatus.label, "Leaving this home is not yet confirmed")
        XCTAssertTrue(app.staticTexts[homeName].exists)
        let retainedCopy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Your personal cart and purchase history stay saved.")).element
        reveal(retainedCopy, in: app)
        XCTAssertTrue(retainedCopy.label.contains("Unsent checkout and undo changes won’t be sent automatically if you join again."))
        let check = app.buttons["shopping.home.checkLeaveStatus"]
        reveal(check, in: app)
        let checking = app.descendants(matching: .any)
            .matching(identifier: "shopping.home.checkingLeaveStatus").element
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            check.isEnabled && !checking.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 8), .completed)
        check.tap()
        let error = app.staticTexts["shopping.home.leaveError"]
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            checking.exists && !check.isEnabled && !error.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 5), .completed,
            "The tap must start a new check and clear its previous result")
        XCTAssertTrue(checking.waitForNonExistence(timeout: 8))
        XCTAssertTrue(check.isEnabled)
        reveal(error, in: app)
        XCTAssertEqual(error.label, "iCloud has not confirmed leaving this home. Your personal cart and history remain saved.")
        XCTAssertEqual(retainedStatus.label, "Leaving this home is not yet confirmed")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "shopping.home.resumeLeave.")).element.exists,
            "An already submitted uncertain leave must not offer a second submission")
    }

    func testContributorLeaveDisclosureCanCancelThenConfirmPendingOutcome() {
        let app = launch(role: "contributor")
        openHomeDetails(app)
        let homeName = app.staticTexts["shopping.home.name"].label
        let leave = app.buttons["shopping.home.leave"]
        reveal(leave, in: app)
        XCTAssertTrue(leave.isEnabled)
        leave.tap()
        let confirm = app.buttons["shopping.home.confirmLeave"]
        XCTAssertTrue(confirm.existsOrAppears(timeout: 3))
        XCTAssertTrue(app.navigationBars["Leave home?"].exists)
        // The underlying details title has its own identifier. Exclude that
        // background element and require one visible disclosure title.
        let disclosureNames = app.staticTexts.matching(NSPredicate(format:
            "label == %@ AND identifier != %@", homeName, "shopping.home.name"))
        XCTAssertEqual(disclosureNames.count, 1)
        XCTAssertTrue(disclosureNames.element.isHittable)
        let unsent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Changes that have not finished syncing may not reach the home.")).element
        reveal(unsent, in: app)
        let retained = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Your personal cart and purchase history stay saved.")).element
        reveal(retained, in: app)
        XCTAssertTrue(retained.label.contains("Unsent checkout and undo changes won’t be sent automatically if you join again."))
        let cancel = app.buttons["shopping.home.cancelLeave"]
        XCTAssertTrue(cancel.existsOrAppears(timeout: 3))
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        let status = app.staticTexts["shopping.home.leaveStatus"]
        XCTAssertFalse(status.exists, "Cancel must not submit a leave operation")
        reveal(leave, in: app)
        XCTAssertTrue(leave.isEnabled)
        leave.tap()
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        reveal(status, in: app)
        XCTAssertEqual(status.label,
            "Leaving this home is still being verified. Your personal cart and history are retained.")
        XCTAssertTrue(leave.exists)
        XCTAssertFalse(leave.isEnabled, "An unresolved leave cannot be submitted again")
        XCTAssertFalse(app.staticTexts["shopping.home.error"].exists)
    }

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

    /// Service tests own durable removal and server-result reconciliation. This
    /// workflow proves the native Stop sharing control binds both confirmation
    /// choices and preserves the currently displayed owner home and groceries.
    func testOwnerStopSharingCanCancelThenRemoveAcceptedAndPendingMembers() {
        let app = launch(role: "owner")
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.row."))
        // Populated has seven active needs; Party ice is archived, and the legacy
        // Strawberries cart flag does not grant this authenticated shopper a cart.
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in rows.count == 7 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 8), .completed)
        let savedGroceries = Set(rows.allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(savedGroceries.count, 7)
        openHomeDetails(app)
        let homeName = app.staticTexts["shopping.home.name"].label
        let invite = app.buttons["shopping.home.invite"]
        reveal(invite, in: app)
        invite.tap()
        let confirmInvite = app.buttons["shopping.home.confirmInvite"]
        reveal(confirmInvite, in: app)
        confirmInvite.tap()
        dismissSystemShareSheet(app)
        let counts = app.staticTexts["shopping.home.memberCounts"]
        reveal(counts, in: app, towardTop: true)
        XCTAssertEqual(counts.label, "1 other accepted members · 1 pending invitations")

        let stop = app.buttons["shopping.home.stopSharing"]
        reveal(stop, in: app)
        stop.tap()
        let confirm = app.buttons["shopping.home.confirmRemoval"]
        XCTAssertTrue(confirm.existsOrAppears(timeout: 3))
        XCTAssertTrue(app.staticTexts["Remove the 2 members and pending invitations captured below? Anyone added after this confirmation was prepared is not included."].exists)
        app.navigationBars["Change sharing access"].buttons["Cancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        reveal(counts, in: app, towardTop: true)
        XCTAssertEqual(counts.label, "1 other accepted members · 1 pending invitations")
        let resend = app.buttons["shopping.home.resend.fixture-invitation-1"]
        reveal(resend, in: app)
        XCTAssertTrue(resend.isEnabled, "Cancelling must retain the pending invitation")

        reveal(stop, in: app)
        stop.tap()
        reveal(confirm, in: app)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        reveal(counts, in: app, towardTop: true)
        XCTAssertEqual(counts.label, "0 other accepted members · 0 pending invitations")
        XCTAssertEqual(app.staticTexts["shopping.home.name"].label, homeName)
        XCTAssertTrue(app.staticTexts["Morgan · You"].exists)
        XCTAssertFalse(app.buttons["shopping.home.remove.fixture-long-name"].exists)
        XCTAssertFalse(resend.exists)
        reveal(invite, in: app)
        XCTAssertTrue(invite.isEnabled)
        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        let preserved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Set(rows.allElementsBoundByIndex.map(\.identifier)) == savedGroceries
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [preserved], timeout: 8), .completed)
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)), savedGroceries)
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
        // Temporary iOS 18.5 diagnosis: isolate the launch-size override.
        // Keep the large-text assertion and unfiltered audit; this is not XXXL proof.
        let app = launch(role: "restricted")
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
        try app.performAccessibilityAudit(for: [.dynamicType]) { issue in
            let details = "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element")"
            let attachment = XCTAttachment(string: details)
            attachment.name = "Home members Dynamic Type audit details"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            return false
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Home members without size override (diagnostic)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let refresh = app.buttons["Check members again"]
        reveal(refresh, in: app)
        XCTAssertTrue(refresh.isEnabled)
        refresh.tap()
        XCTAssertFalse(app.staticTexts["shopping.home.error"].exists)
        XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
    }

    private func launch(role: String, largestText: Bool = false, rootGoneLeave: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_HOME_MEMBERS"] = role
        if rootGoneLeave { app.launchEnvironment["SHOPPING_UI_TEST_HOME_LEAVE_ROOT_GONE"] = "1" }
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
