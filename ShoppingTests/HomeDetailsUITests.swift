import XCTest

final class HomeDetailsUITests: XCTestCase {
    func testOwnerDeleteRequiresExactHomeConfirmationAndCanRecreateAfterRelaunch() throws {
        let app = launch(role: "owner")
        openHomeDetails(app)
        let delete = app.buttons["shopping.home.delete"]
        reveal(delete, in: app)
        delete.tap()
        let alert = app.alerts["Delete “Preview household”?"]
        XCTAssertTrue(alert.existsOrAppears(timeout: 3))
        XCTAssertTrue(app.staticTexts["Deletes its list, catalog, and settings for everyone. This can’t be undone."].exists)
        try alertAction("Cancel", id: "shopping.home.cancelDelete", in: alert).tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["shopping.home.deletionStatus"].exists,
            "Cancel must leave the home available and submit no deletion")
        reveal(delete, in: app)
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        XCTAssertTrue(alert.existsOrAppears(timeout: 3))
        try alertAction("Delete Home", id: "shopping.home.confirmDelete", in: alert).tap()
        XCTAssertTrue(app.staticTexts["No Homes"].existsOrAppears(timeout: 8))
        XCTAssertTrue(app.buttons["shopping.home.createFirst"].exists)
        XCTAssertTrue(app.buttons["shopping.home.savedCarts"].exists,
            "Private cart recovery must remain reachable after deleting the only home")
        app.buttons["shopping.home.savedCarts"].tap()
        XCTAssertTrue(app.navigationBars["Saved carts"].existsOrAppears(timeout: 3))
        app.navigationBars["Saved carts"].buttons.firstMatch.tap()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.staticTexts["No Homes"].existsOrAppears(timeout: 8))
        XCTAssertTrue(app.buttons["shopping.home.savedCarts"].exists)
        app.buttons["shopping.home.createFirst"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        XCTAssertFalse(app.buttons["shopping.home.scope"].exists)
        app.tabBars.buttons["Settings"].tap()
        let scope = app.buttons["shopping.home.scope"]
        XCTAssertTrue(scope.existsOrAppears(timeout: 3))
        XCTAssertTrue((scope.value as? String)?.contains("My Home") == true)
    }

    /// A suspended read proves the cloud navigation stays interactive and that
    /// background activity retains useful navigation, both on entry and return.
    func testCloudToolbarStaysInteractiveDuringHomeRefreshAndReturn() {
        let app = launch(role: "owner", delayedRefresh: true)
        openHomeDetails(app)
        let cloud = app.buttons["shopping.home.sharingStatus"]
        XCTAssertTrue(cloud.existsOrAppears(timeout: 3))
        XCTAssertTrue(cloud.isEnabled)
        XCTAssertTrue(cloud.isHittable)
        XCTAssertEqual(cloud.value as? String, "Checking home")
        cloud.tap()
        XCTAssertTrue(app.navigationBars["Sharing status"].existsOrAppears(timeout: 3))
        let back = app.navigationBars["Sharing status"].buttons.element
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.navigationBars["Home Settings"].existsOrAppears(timeout: 3))
        XCTAssertTrue(cloud.isHittable)
        XCTAssertEqual(cloud.value as? String, "Checking home")
        let checkingFrame = cloud.frame
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cloud.value as? String != "Checking home"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 15), .completed)
        XCTAssertEqual(cloud.frame.origin.x, checkingFrame.origin.x, accuracy: 1)
        XCTAssertEqual(cloud.frame.size.width, checkingFrame.size.width, accuracy: 1)
        XCTAssertEqual(cloud.frame.size.height, checkingFrame.size.height, accuracy: 1)
        XCTAssertFalse(app.buttons["shopping.home.manageHomes"].exists)
        XCTAssertFalse(app.buttons["shopping.home.create"].exists)
        XCTAssertTrue(app.buttons["shopping.home.rename"].isHittable)
        XCTAssertTrue(app.buttons["shopping.home.invite"].isHittable)
    }

    func testSubmittedLeaveWithMissingRootKeepsStatusReachableThroughHomes() throws {
        let app = launch(role: "contributor", rootGoneLeave: true)
        openHomeDetails(app)
        let homeName = "Preview household"
        let leave = app.buttons["shopping.home.leave"]
        reveal(leave, in: app)
        leave.tap()
        let alert = app.alerts["Leave “Preview household”?"]
        XCTAssertTrue(alert.existsOrAppears(timeout: 3))
        let confirm = try alertAction("Leave Home", id: "shopping.home.confirmLeave", in: alert)
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        let chooseHome = app.buttons["Homes"]
        XCTAssertTrue(chooseHome.existsOrAppears(timeout: 8))
        XCTAssertTrue(chooseHome.isHittable)
        XCTAssertTrue(app.buttons["shopping.home.savedCarts"].exists)
        chooseHome.tap()
        XCTAssertTrue(app.navigationBars["Homes"].existsOrAppears(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.home.choice.", homeName)).element.exists,
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

    func testContributorLeaveAlertCanCancelThenConfirmPendingOutcome() throws {
        let app = launch(role: "contributor")
        openHomeDetails(app)
        let homeName = "Preview household"
        let leave = app.buttons["shopping.home.leave"]
        reveal(leave, in: app)
        XCTAssertTrue(leave.isEnabled)
        leave.tap()
        let alert = app.alerts["Leave “\(homeName)”?"]
        XCTAssertTrue(alert.existsOrAppears(timeout: 3))
        let confirm = try alertAction("Leave Home", id: "shopping.home.confirmLeave", in: alert)
        XCTAssertTrue(confirm.exists)
        XCTAssertTrue(app.staticTexts["You’ll need another invite to rejoin."].exists)
        let cancel = try alertAction("Cancel", id: "shopping.home.cancelLeave", in: alert)
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        let status = app.staticTexts["shopping.home.leaveStatus"]
        XCTAssertFalse(status.exists, "Cancel must not submit a leave operation")
        reveal(leave, in: app)
        XCTAssertTrue(leave.isEnabled)
        leave.tap()
        XCTAssertTrue(confirm.existsOrAppears(timeout: 3))
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        reveal(status, in: app)
        XCTAssertEqual(status.label, "Leaving home is still being confirmed.")
        XCTAssertTrue(leave.exists)
        XCTAssertFalse(leave.isEnabled, "An unresolved leave cannot be submitted again")
        XCTAssertFalse(app.staticTexts["shopping.home.error"].exists)
    }

    func testOwnerRemovalConfirmationCanCancelThenRemoveOnlyContributor() throws {
        let app = launch(role: "owner")
        openHomeDetails(app)
        let remove = app.buttons["shopping.home.remove.fixture-long-name"]
        openMemberMenu("fixture-long-name", app: app)
        XCTAssertTrue(remove.existsOrAppears(timeout: 3))
        remove.tap()
        let alert = app.alerts["Remove “Alexandra Penelope Montgomery-Wellington”?"]
        XCTAssertTrue(alert.existsOrAppears(timeout: 3))
        let confirm = try alertAction("Remove Member", id: "shopping.home.confirmRemoval", in: alert)
        XCTAssertTrue(confirm.isEnabled)
        try alertAction("Cancel", id: "shopping.home.cancelRemoval", in: alert).tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        assertMembership(app, contributor: true, invitation: false)
        openMemberMenu("fixture-long-name", app: app)
        XCTAssertTrue(remove.existsOrAppears(timeout: 3))
        remove.tap()
        XCTAssertTrue(alert.existsOrAppears(timeout: 3))
        let confirmedRemoval = try alertAction("Remove Member", id: "shopping.home.confirmRemoval", in: alert)
        XCTAssertTrue(confirmedRemoval.isEnabled)
        confirmedRemoval.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        assertMembership(app, contributor: false, invitation: false)
        XCTAssertTrue(app.staticTexts["Morgan · You"].exists)
        XCTAssertFalse(app.buttons["shopping.home.remove.fixture-owner"].exists)
        XCTAssertFalse(remove.exists)
        let invite = app.buttons["shopping.home.invite"]
        reveal(invite, in: app)
        XCTAssertTrue(invite.isEnabled)
    }

    func testInviteFailureShowsActualProblemWithoutInventingPendingInvitationOrCloudFailure() {
        let app = launch(role: "owner", inviteFailure: true)
        openHomeDetails(app)
        nameInvitation("Beka", app: app)
        let error = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "shopping.home.invitation.error.")).element
        reveal(error, in: app)
        XCTAssertEqual(error.label, "This home’s saved identities conflict. Sharing is unavailable; your groceries are retained.")
        XCTAssertTrue(app.navigationBars["Beka"].exists)
        XCTAssertFalse(app.staticTexts["shopping.home.member.fixture-invitation-1"].exists)
        XCTAssertFalse(app.buttons["Close"].exists)
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "shopping.home.invitation.retry.")).element
        reveal(retry, in: app)
        retry.tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        assertReadyInvitation(app)
        returnToHomeDetails(app)
        XCTAssertNotEqual(app.buttons["shopping.home.sharingStatus"].value as? String, "Needs attention")
        assertMembership(app, contributor: true, invitation: true)
    }

    /// Named invitation creation, explicit delivery and cancellation preserve the
    /// grocery identities and require confirmation before removing the invitee.
    func testOwnerInviteAndCancelPendingInvitationPreservesGroceries() throws {
        let app = launch(role: "owner")
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.grocery.row."))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in rows.count == 7 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 8), .completed)
        let savedGroceries = Set(rows.allElementsBoundByIndex.map(\.identifier))
        openHomeDetails(app)
        attachScreenshot("Home Settings before invitation", app: app)
        nameInvitation("Beka", app: app, capture: true)
        assertReadyInvitation(app)
        attachScreenshot("Named invitation ready to share", app: app)
        shareInvitation(app)
        XCTAssertTrue(app.buttons["Close"].existsOrAppears(timeout: 5))
        attachScreenshot("System invitation share sheet", app: app)
        dismissSystemShareSheet(app)
        assertReadyInvitation(app)
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "shopping.home.invitation.cancel.")).element
        reveal(remove, in: app)
        remove.tap()
        let alert = app.alerts["Cancel invitation to “Beka”?"]
        XCTAssertTrue(alert.existsOrAppears(timeout: 3))
        attachScreenshot("Named invitation cancellation confirmation", app: app)
        let confirm = try alertAction("Cancel Invitation", id: "shopping.home.confirmRemoval", in: alert)
        XCTAssertTrue(confirm.isHittable)
        try alertAction("Cancel", id: "shopping.home.cancelRemoval", in: alert).tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        assertReadyInvitation(app)
        reveal(remove, in: app)
        remove.tap()
        XCTAssertTrue(alert.existsOrAppears(timeout: 3))
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        returnToHomeDetails(app)
        assertMembership(app, contributor: true, invitation: false)
        XCTAssertTrue(app.staticTexts["Morgan · You"].exists)
        app.tabBars.buttons["Groceries"].tap()
        let preserved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Set(rows.allElementsBoundByIndex.map(\.identifier)) == savedGroceries
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [preserved], timeout: 8), .completed)
    }

    func testOwnerDirectShareCancellationKeepsPendingInvitationAvailableToResend() {
        let app = launch(role: "owner")
        openHomeDetails(app)
        assertMembership(app, contributor: true, invitation: false)
        nameInvitation("Beka", app: app)
        XCTAssertTrue(app.staticTexts["Anyone with this link can join. One person per link."].exists)
        shareInvitation(app)
        dismissSystemShareSheet(app)
        assertReadyInvitation(app)
        returnToHomeDetails(app)
        assertMembership(app, contributor: true, invitation: true)
        let originalID = invitationRow(app).identifier
        nameInvitation("  beka  ", app: app, reusingExisting: true)
        assertReadyInvitation(app)
        shareInvitation(app)
        dismissSystemShareSheet(app)
        assertReadyInvitation(app)
        returnToHomeDetails(app)
        XCTAssertEqual(invitationRow(app).identifier, originalID, "Normalized duplicate names must reuse the same invitation")
        XCTAssertFalse(app.staticTexts["shopping.home.member.fixture-invitation-2"].exists)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        openHomeDetails(app)
        let restored = invitationRow(app)
        reveal(restored, in: app)
        XCTAssertEqual(restored.identifier, originalID)
        XCTAssertTrue(restored.label.contains("Beka"))
        restored.tap()
        assertReadyInvitation(app)
        shareInvitation(app)
        dismissSystemShareSheet(app)
        assertReadyInvitation(app)
    }

    func testContributorCanRenameHomeButCannotInviteAndNameSurvivesRelaunch() {
        let app = launch(role: "contributor")
        openHomeDetails(app)
        XCTAssertTrue(app.staticTexts["Taylor · You"].existsOrAppears(timeout: 3))
        XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
        XCTAssertFalse(app.buttons["shopping.home.delete"].exists)
        XCTAssertFalse(app.buttons["shopping.home.stopSharing"].exists)
        XCTAssertFalse(app.buttons["shopping.home.remove.fixture-long-name"].exists)
        let rename = app.buttons["shopping.home.rename"]
        XCTAssertTrue(rename.existsOrAppears(timeout: 3))
        XCTAssertTrue(rename.isHittable)
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
        let saved = app.buttons["shopping.home.rename"]
        XCTAssertTrue(saved.existsOrAppears(timeout: 5))
        XCTAssertTrue(saved.label.contains("Shared kitchen"))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        openHomeDetails(app, name: "Shared kitchen")
        XCTAssertTrue(saved.existsOrAppears(timeout: 5))
        XCTAssertTrue(saved.label.contains("Shared kitchen"))
        XCTAssertFalse(app.buttons["shopping.home.invite"].exists)
    }

    func testRestrictedMembershipAndLongNamesRemainReadableAtAccessibilityTextSize() throws {
        continueAfterFailure = false
        let app = launch(role: "restricted", systemTextSize: true)
        let textSize = try SystemTextSizeSettings(test: self, app: app)
        openHomeDetails(app)
        let homeName = "Home Settings"
        let home = app.staticTexts["shopping.home.membersHeading"]
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
            XCTAssertTrue(app.navigationBars[homeName].exists)
            XCTAssertTrue(home.exists)
            XCTAssertEqual(home.label, "Members")
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
            app.buttons["shopping.home.sharingStatus"].value as? String != "Checking home"
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

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func nameInvitation(_ name: String, app: XCUIApplication, reusingExisting: Bool = false, capture: Bool = false) {
        let invite = app.buttons["shopping.home.invite"]
        reveal(invite, in: app)
        XCTAssertTrue(invite.isEnabled)
        invite.tap()
        let field = app.textFields["shopping.home.invitation.name"]
        XCTAssertTrue(field.existsOrAppears(timeout: 3))
        field.tap()
        let previous = field.value as? String ?? ""
        let content = previous == "Name" ? "" : previous
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: content.count) + name)
        XCTAssertEqual(field.value as? String, name)
        if capture { attachScreenshot("Invitation name form", app: app) }
        let create = app.buttons["shopping.home.invitation.create"]
        if reusingExisting {
            XCTAssertFalse(create.isEnabled, "An existing named invitation is continued rather than created again")
            let existing = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                "shopping.home.invitation.existing.")).element
            XCTAssertTrue(existing.existsOrAppears(timeout: 3))
            XCTAssertTrue(existing.isHittable)
            existing.tap()
        } else {
            XCTAssertTrue(create.isEnabled)
            create.tap()
        }
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    private func invitationRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.home.invitation.row.")).element
    }

    private func assertReadyInvitation(_ app: XCUIApplication) {
        let status = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "shopping.home.invitation.status.")).element
        XCTAssertTrue(status.existsOrAppears(timeout: 5))
        XCTAssertEqual(status.label, "Ready to share")
    }

    private func shareInvitation(_ app: XCUIApplication) {
        let share = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "shopping.home.invitation.share.")).element
        reveal(share, in: app)
        XCTAssertTrue(share.isEnabled)
        share.tap()
    }

    private func returnToHomeDetails(_ app: XCUIApplication) {
        if !app.navigationBars["Home Settings"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars["Home Settings"].existsOrAppears(timeout: 3))
    }

    private func openMemberMenu(_ id: String, app: XCUIApplication) {
        let menu = app.buttons["shopping.home.memberActions." + id]
        reveal(menu, in: app)
        menu.tap()
    }

    private func alertAction(_ label: String, id: String, in alert: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let leaves = alert.buttons.matching(NSPredicate(format: "label == %@", label))
            .allElementsBoundByIndex.filter { $0.descendants(matching: .button).count == 0 }
        XCTAssertEqual(leaves.count, 1, "Expected one native alert action", file: file, line: line)
        let button = try XCTUnwrap(leaves.first, file: file, line: line)
        XCTAssertEqual(button.identifier, id, file: file, line: line)
        return button
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
        let pending = invitationRow(app)
        if invitation {
            reveal(pending, in: app)
            XCTAssertTrue(pending.label.contains("Beka"))
        } else {
            XCTAssertTrue(pending.waitForNonExistence(timeout: 5))
        }
        XCTAssertFalse(app.staticTexts["shopping.home.memberCounts"].exists)
    }

    private func launch(role: String, systemTextSize: Bool = false, rootGoneLeave: Bool = false, delayedRefresh: Bool = false, inviteFailure: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_HOME_MEMBERS"] = role
        if inviteFailure { app.launchEnvironment["SHOPPING_UI_TEST_HOME_INVITE_FAILURE"] = "1" }
        if delayedRefresh { app.launchEnvironment["SHOPPING_UI_TEST_HOME_REFRESH_DELAY"] = "1" }
        if rootGoneLeave { app.launchEnvironment["SHOPPING_UI_TEST_HOME_LEAVE_ROOT_GONE"] = "1" }
        if systemTextSize { SystemTextSizeSettings.configure(app) }
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        return app
    }

    private func openHomeDetails(_ app: XCUIApplication, name: String = "Preview household") {
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        app.tabBars.buttons["Settings"].tap()
        let details = app.buttons["shopping.settings.homeDetails"]
        reveal(details, in: app)
        details.tap()
        XCTAssertTrue(app.navigationBars["Home Settings"].existsOrAppears(timeout: 5))
        let nameRow = app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS %@ AND label CONTAINS %@", "Name", name)).firstMatch
        XCTAssertTrue(nameRow.existsOrAppears(timeout: 5), "Home Settings must show the selected home's name")
        XCTAssertTrue(app.staticTexts["shopping.home.membersHeading"].existsOrAppears(timeout: 5))
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
