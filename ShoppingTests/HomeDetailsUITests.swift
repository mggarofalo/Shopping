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
        XCTAssertTrue(app.navigationBars["Manage homes"].existsOrAppears(timeout: 5))
        XCTAssertFalse(app.buttons["shopping.home.choice." + homeName].exists,
            "The deleted shared root must not remain available as a home choice")
        let retainedStatus = app.staticTexts.matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "shopping.home.leaveStatus.")).element
        reveal(retainedStatus, in: app)
        XCTAssertEqual(retainedStatus.label, "Leaving this home is not yet confirmed")
        XCTAssertTrue(app.staticTexts[homeName].exists)
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
        XCTAssertEqual(status.label, "Leaving home is still being confirmed.")
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
        assertMembership(app, contributor: false, invitation: false)
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
        assertMembership(app, contributor: true, invitation: true)

        let stop = app.buttons["shopping.home.stopSharing"]
        reveal(stop, in: app)
        stop.tap()
        let confirm = app.buttons["shopping.home.confirmRemoval"]
        XCTAssertTrue(confirm.existsOrAppears(timeout: 3))
        XCTAssertTrue(app.staticTexts["Remove access for the people below?"].exists)
        app.navigationBars["Change sharing access"].buttons["Cancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        assertMembership(app, contributor: true, invitation: true)
        let resend = app.buttons["shopping.home.resend.fixture-invitation-1"]
        reveal(resend, in: app)
        XCTAssertTrue(resend.isEnabled, "Cancelling must retain the pending invitation")

        reveal(stop, in: app)
        stop.tap()
        reveal(confirm, in: app)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        assertMembership(app, contributor: false, invitation: false)
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
        assertMembership(app, contributor: true, invitation: false)
        XCTAssertFalse(app.buttons["shopping.home.stopSharing"].exists, "One member has one removal action")
        XCTAssertTrue(app.staticTexts["Morgan · You"].existsOrAppears(timeout: 3))
        let invite = app.buttons["shopping.home.invite"]
        reveal(invite, in: app)
        invite.tap()
        let confirm = app.buttons["shopping.home.confirmInvite"]
        XCTAssertTrue(confirm.existsOrAppears(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Personal carts and purchase history stay private.")).element.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Anyone with the link can claim it.")).element.exists)
        app.navigationBars["Invite contributor"].buttons["Cancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        assertMembership(app, contributor: true, invitation: false)
        reveal(invite, in: app)
        invite.tap()
        reveal(confirm, in: app)
        confirm.tap()
        dismissSystemShareSheet(app)
        assertMembership(app, contributor: true, invitation: true)
        let resend = app.buttons["shopping.home.resend.fixture-invitation-1"]
        reveal(resend, in: app)
        XCTAssertTrue(app.staticTexts["Invitation pending"].existsOrAppears(timeout: 3))
        resend.tap()
        dismissSystemShareSheet(app)
        assertMembership(app, contributor: true, invitation: true)
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
        continueAfterFailure = false
        let app = launch(role: "restricted", systemTextSize: true)
        let textSize = try SystemTextSizeSettings(test: self, app: app)
        openHomeDetails(app)
        let home = app.staticTexts["shopping.home.name"]
        let homeName = home.label
        let longName = app.staticTexts["Alexandra Penelope Montgomery-Wellington"]
        let witnesses: [(String, XCUIElement)] = [
            ("headline", home),
            ("subheadline", app.staticTexts["Read-only access"]),
            ("body", longName)
        ]
        func measure(_ phase: String) -> [String: CGRect] {
            var frames: [String: CGRect] = [:]
            for (role, element) in witnesses {
                reveal(element, in: app, towardTop: role == "headline")
                frames[role] = element.frame
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Home members \(phase) \(role) fully visible"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            return frames
        }
        func assertRetainedDestination() {
            // List can virtualize deep members after reflow. First establish the
            // retained destination/home, without reopening it or scrolling.
            XCTAssertTrue(app.navigationBars["Home"].exists)
            XCTAssertTrue(home.exists)
            XCTAssertEqual(home.label, homeName)
            XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
        }
        let baseline = measure("Large")
        reveal(home, in: app, towardTop: true)
        try textSize.set(.accessibilityXXXL)
        assertRetainedDestination()
        XCTAssertFalse(app.buttons["shopping.home.rename"].exists,
            "Read-only members should not see an action they cannot use")
        XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
        let current = app.staticTexts["Taylor · You"]
        reveal(current, in: app)
        XCTAssertEqual(current.label, "Taylor · You")
        let enlarged = measure("accessibility XXXL")
        XCTAssertEqual(longName.label, "Alexandra Penelope Montgomery-Wellington")
        XCTAssertGreaterThan(longName.frame.height, 44, "The full member name should wrap at accessibility text sizes.")
        for (role, frame) in enlarged {
            XCTAssertGreaterThan(frame.height, baseline[role]!.height + 1, "\(role) must actually grow after the system change")
        }
        XCTAssertFalse(app.buttons["Check members again"].exists, "Healthy members have native refresh")
        reveal(home, in: app, towardTop: true)
        app.swipeDown()
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.descendants(matching: .any).matching(identifier: "shopping.home.checking").element.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 8), .completed)
        XCTAssertFalse(app.staticTexts["shopping.home.error"].exists)
        XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
        reveal(home, in: app, towardTop: true)
        try textSize.set(.large)
        assertRetainedDestination()
        let returned = measure("Large restored")
        for (role, frame) in returned {
            XCTAssertEqual(frame.height, baseline[role]!.height, accuracy: 2, "\(role) must return to its original rendered size")
            XCTAssertEqual(frame.width, baseline[role]!.width, accuracy: 2)
        }
    }

    private func assertMembership(_ app: XCUIApplication, contributor: Bool, invitation: Bool) {
        let owner = app.staticTexts["shopping.home.member.fixture-owner"]
        reveal(owner, in: app, towardTop: true)
        XCTAssertEqual(owner.label, "Morgan · You")
        let member = app.staticTexts["shopping.home.member.fixture-long-name"]
        if contributor {
            reveal(member, in: app)
            XCTAssertEqual(member.label, "Alexandra Penelope Montgomery-Wellington")
        } else {
            XCTAssertTrue(member.waitForNonExistence(timeout: 5))
        }
        let pending = app.staticTexts["shopping.home.member.fixture-invitation-1"]
        if invitation {
            reveal(pending, in: app)
            XCTAssertEqual(pending.label, "Invitation pending")
        } else {
            XCTAssertTrue(pending.waitForNonExistence(timeout: 5))
        }
        XCTAssertFalse(app.staticTexts["shopping.home.memberCounts"].exists)
    }

    private func launch(role: String, systemTextSize: Bool = false, rootGoneLeave: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_HOME_MEMBERS"] = role
        if rootGoneLeave { app.launchEnvironment["SHOPPING_UI_TEST_HOME_LEAVE_ROOT_GONE"] = "1" }
        if systemTextSize { SystemTextSizeSettings.configure(app) }
        app.launch()
        return app
    }

    private func openHomeDetails(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        app.tabBars.buttons["Settings"].tap()
        let details = app.buttons["shopping.settings.homeDetails"]
        reveal(details, in: app)
        details.tap()
        XCTAssertTrue(app.navigationBars["Home"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.staticTexts["shopping.home.name"].existsOrAppears(timeout: 5))
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
            if element.exists {
                // Page swipes can oscillate past a short witness after layout reflow.
                // Move by its measured clipping distance, retaining full containment.
                let frame = element.frame
                let distance = frame.minY < top ? top - frame.minY + 16 : bottom - frame.maxY - 16
                let limit = (bottom - top) / 3
                let offset = max(-limit, min(limit, distance))
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: app.frame.midX, dy: (top + bottom) / 2))
                start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: offset)))
            } else if towardTop { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.existsOrAppears(timeout: 3), file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY - 20
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.minY, top, "The complete control must be below the navigation bar", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bottom, "The complete control must be above the tab bar", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX, file: file, line: line)
    }
}
