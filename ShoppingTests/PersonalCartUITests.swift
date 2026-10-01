import XCTest

final class PersonalCartUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPersonalCheckoutAndRecoverySurviveRelaunch() {
        let app = launch()
        let grocery = groceryRow("Granola", app: app)
        XCTAssertTrue(grocery.waitForExistence(timeout: 8))
        grocery.swipeLeft()
        let cartAction = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.checklist.cart.")).firstMatch
        XCTAssertTrue(cartAction.waitForExistence(timeout: 3))
        cartAction.tap()
        app.buttons["In cart (1)"].tap()
        XCTAssertTrue(app.navigationBars["My cart"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Granola moved to In cart."].waitForNonExistence(timeout: 5))
        let checkout = app.buttons["Check out"]
        XCTAssertTrue(checkout.isHittable)
        checkout.tap()
        XCTAssertTrue(app.navigationBars["Check out"].waitForExistence(timeout: 3))
        app.buttons["Confirm"].tap()
        XCTAssertTrue(app.staticTexts["Your cart is empty in this view"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 8))
        XCTAssertFalse(groceryRow("Granola", app: app).exists)
        app.buttons["Recently cleared"].tap()
        XCTAssertTrue(app.navigationBars["My purchases"].waitForExistence(timeout: 3))
        app.buttons["Undo this purchase"].tap()
        XCTAssertTrue(app.staticTexts["Purchase undone"].waitForExistence(timeout: 3))
        app.navigationBars["My purchases"].buttons.firstMatch.tap()
        app.buttons["In cart (1)"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).firstMatch.waitForExistence(timeout: 3))
    }

    func testLegacyCartRequiresExplicitClaim() {
        let app = launch()
        XCTAssertTrue(app.buttons["In cart (0)"].waitForExistence(timeout: 8))
        openLegacyReview(app)
        XCTAssertTrue(app.navigationBars["Old cart entries"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Strawberries"].exists)
        app.buttons.matching(identifier: "Claim as mine").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Claimed as mine"].waitForExistence(timeout: 3))
        app.navigationBars["Old cart entries"].buttons.firstMatch.tap()
        app.navigationBars["My cart"].buttons.firstMatch.tap()
        app.buttons["In cart (1)"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Strawberries")).firstMatch.waitForExistence(timeout: 3))
    }

    func testHouseholdSetupAccountFailureKeepsVisibleGroceriesAfterRelaunch() {
        let app = launch(personalCart: false, unavailableSetup: true)
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["shopping.settings.homeDetails"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        app.buttons["Copy this device’s groceries to iCloud"].tap()
        app.buttons["Copy groceries"].tap()
        XCTAssertTrue(app.staticTexts["Your iCloud account is temporarily unavailable. Try again later."].existsOrAppears(timeout: 8))
        XCTAssertTrue(app.navigationBars["Home"].exists)
        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 3))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 3))
    }

    func testLegacyDiscardRemovesPendingCardAfterRelaunchAndKeepsEarlierHistoryRoute() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 8))
        openLegacyReview(app)
        XCTAssertTrue(app.staticTexts["Strawberries"].waitForExistence(timeout: 3))
        app.buttons.matching(identifier: "Discard old cart status").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Old cart status discarded"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Strawberries"].exists)
        XCTAssertTrue(app.buttons["Earlier cleared groceries"].exists)
        app.buttons["Earlier cleared groceries"].tap()
        XCTAssertTrue(app.navigationBars["Recently cleared"].waitForExistence(timeout: 3))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 8))
        app.buttons["In cart (0)"].tap()
        XCTAssertTrue(app.navigationBars["My cart"].existsOrAppears(timeout: 3))
        XCTAssertFalse(app.buttons["shopping.personalCart.legacyReview"].exists)
        XCTAssertFalse(app.buttons["Claim as mine"].exists)
        app.navigationBars["My cart"].buttons.firstMatch.tap()
        app.buttons["Recently cleared"].tap()
        XCTAssertTrue(app.navigationBars["My purchases"].existsOrAppears(timeout: 3))
        let earlier = app.buttons["shopping.personalCart.earlierHistory"]
        XCTAssertTrue(earlier.existsOrAppears(timeout: 5))
        XCTAssertTrue(earlier.isHittable)
        earlier.tap()
        XCTAssertTrue(app.navigationBars["Recently cleared"].existsOrAppears(timeout: 3))
        let restore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.recovery.restore.")).element
        XCTAssertTrue(restore.existsOrAppears(timeout: 3))
        restore.tap()
        app.navigationBars["Recently cleared"].buttons.firstMatch.tap()
        app.navigationBars["My purchases"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 3))
        let search = app.searchFields["Search groceries"]
        XCTAssertTrue(search.existsOrAppears(timeout: 3))
        search.tap()
        search.typeText("Party ice")
        XCTAssertEqual(search.value as? String, "Party ice")
        XCTAssertTrue(groceryRow("Party ice", app: app).existsOrAppears(timeout: 5))
    }

    func testOtherPurchaseKeepsOwnEntryUntilExplicitBuyAnyway() {
        let app = launch(purchaseNotice: true)
        XCTAssertTrue(app.buttons["In cart (1)"].waitForExistence(timeout: 8))
        app.buttons["In cart (1)"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.staticTexts["Already purchased"].waitForExistence(timeout: 3))
        app.buttons["Buy anyway"].tap()
        XCTAssertTrue(app.navigationBars["Check out"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Confirm"].isEnabled)
        let acknowledgement = app.switches["Already purchased. Buy anyway"]
        acknowledgement.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(acknowledgement.value as? String, "1")
        XCTAssertTrue(app.buttons["Confirm"].isEnabled)
        app.buttons["Confirm"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Your cart is empty in this view"].waitForExistence(timeout: 3))
    }

    func testPurchasedRememberedItemCanBeRequestedAgain() {
        let app = launch(purchaseNotice: true)
        XCTAssertTrue(app.buttons["In cart (1)"].waitForExistence(timeout: 8))
        XCTAssertFalse(groceryRow("Granola", app: app).exists)
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Granola")
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.grocery.catalogResult.", "Granola")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
        XCTAssertTrue(groceryRow("Granola", app: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["In cart (1)"].exists)
    }

    func testRetainedCartCanBeRemovedAfterHouseholdDisappears() {
        let app = launch(revoked: true)
        XCTAssertTrue(app.staticTexts["Waiting for your household"].waitForExistence(timeout: 8))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.staticTexts["Waiting for your household"].waitForExistence(timeout: 8))
        app.buttons["Saved personal carts"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Saved personal cart")).firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        app.buttons["Remove from my cart"].tap()
        XCTAssertTrue(app.staticTexts["Your cart is empty in this view"].waitForExistence(timeout: 3))
    }

    func testDismissPendingInvitationPersistsAfterRelaunchAndKeepsGroceries() {
        let app = launch(activeHomes: true, pendingInvitation: true)
        let notice = app.buttons["shopping.home.invitation"]
        XCTAssertTrue(notice.existsOrAppears(timeout: 8))
        XCTAssertTrue(notice.isHittable)
        notice.tap()
        XCTAssertTrue(app.staticTexts["Invitation waiting"].existsOrAppears(timeout: 3))
        app.buttons["Dismiss invitation"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        let choose = app.buttons["Choose a home"]
        XCTAssertTrue(choose.existsOrAppears(timeout: 3))
        choose.tap()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        openManageHomes(app)
        let original = app.buttons["shopping.home.choice.Preview household"]
        XCTAssertTrue(original.existsOrAppears(timeout: 3))
        XCTAssertEqual(original.value as? String, "Owner, Selected")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_PENDING_INVITATION")
        app.launch()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        XCTAssertFalse(notice.exists)
    }

    func testCreateAndSwitchHomesPreservesOriginalGroceriesAfterRelaunch() {
        let app = launch(activeHomes: true)
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        groceryRow("Granola", app: app).swipeLeft()
        let cartAction = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.checklist.cart.")).firstMatch
        XCTAssertTrue(cartAction.existsOrAppears(timeout: 3))
        cartAction.tap()
        XCTAssertTrue(app.staticTexts["Granola moved to In cart."].waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        openManageHomes(app)
        let name = app.textFields["shopping.home.name"]
        XCTAssertTrue(name.existsOrAppears(timeout: 3))
        name.tap()
        name.typeText("Second home")
        XCTAssertEqual(name.value as? String, "Second home")
        app.buttons["shopping.home.create"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        XCTAssertFalse(groceryRow("Granola", app: app).exists)
        app.buttons["In cart (0)"].tap()
        XCTAssertTrue(app.navigationBars["My cart"].existsOrAppears(timeout: 3))
        let saved = app.buttons["shopping.personalCart.otherHomes"]
        XCTAssertTrue(saved.existsOrAppears(timeout: 5))
        XCTAssertTrue(saved.isHittable)
        saved.tap()
        XCTAssertTrue(app.navigationBars["Saved carts"].existsOrAppears(timeout: 3))
        let retained = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Saved personal cart")).element
        XCTAssertTrue(retained.existsOrAppears(timeout: 3))
        retained.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).element.existsOrAppears(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        openManageHomes(app)
        XCTAssertTrue(app.buttons["shopping.home.choice.Second home"].existsOrAppears(timeout: 3))
        XCTAssertEqual(app.buttons["shopping.home.choice.Second home"].value as? String, "Owner, Selected")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        XCTAssertFalse(groceryRow("Granola", app: app).exists)
        app.tabBars.buttons["Settings"].tap()
        openManageHomes(app)
        XCTAssertTrue(app.buttons["shopping.home.choice.Second home"].existsOrAppears(timeout: 3))
        XCTAssertEqual(app.buttons["shopping.home.choice.Second home"].value as? String, "Owner, Selected")
        let original = app.buttons["shopping.home.choice.Preview household"]
        XCTAssertTrue(original.existsOrAppears(timeout: 3))
        original.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.buttons["In cart (1)"].existsOrAppears(timeout: 5))
        app.buttons["In cart (1)"].tap()
        XCTAssertTrue(app.navigationBars["My cart"].existsOrAppears(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).element.existsOrAppears(timeout: 5))
    }

    func testResumeUnacknowledgedHomeCreationRetainsOriginalHomeAfterRelaunch() {
        let app = launch(activeHomes: true, pendingHomeCreation: true)
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_PENDING_HOME_CREATION")
        app.launch()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        app.tabBars.buttons["Settings"].tap()
        openManageHomes(app)
        let resume = app.buttons["Resume creating home"]
        XCTAssertTrue(resume.existsOrAppears(timeout: 3))
        XCTAssertFalse(app.textFields["shopping.home.name"].isEnabled)
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.home.choice."))
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(app.buttons["shopping.home.choice.Preview household"].value as? String, "Owner, Selected")
        resume.tap()
        XCTAssertTrue(resume.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textFields["shopping.home.name"].isEnabled)
        XCTAssertEqual(choices.count, 1)
        app.terminate()
        app.launch()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        app.tabBars.buttons["Settings"].tap()
        openManageHomes(app)
        XCTAssertTrue(app.buttons["Create home"].existsOrAppears(timeout: 3))
        XCTAssertFalse(resume.exists)
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(app.buttons["shopping.home.choice.Preview household"].value as? String, "Owner, Selected")
    }

    func testAccountScopedCatalogDraftSurvivesRelaunchAndCancelDiscardsIt() {
        let app = launch(activeHomes: true)
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        app.tabBars.buttons["Catalog"].tap()
        app.buttons["shopping.catalog.add"].tap()
        let name = app.textFields["shopping.catalog.name"]
        XCTAssertTrue(name.existsOrAppears(timeout: 3))
        name.tap()
        name.typeText("Unfinished milk")
        XCTAssertEqual(name.value as? String, "Unfinished milk")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        app.tabBars.buttons["Catalog"].tap()
        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(name.existsOrAppears(timeout: 3))
        XCTAssertEqual(name.value as? String, "Unfinished milk")
        app.buttons["Cancel"].tap()
        app.buttons["shopping.catalog.add"].tap()
        XCTAssertTrue(name.existsOrAppears(timeout: 3))
        XCTAssertNotEqual(name.value as? String, "Unfinished milk")
    }

    func testInvitationSetupKeepsOriginalOnDeviceAndReturnsAfterRelaunch() {
        let app = launch(personalCart: false, homeAdoption: true)
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        let invitation = app.buttons["shopping.home.invitation"]
        XCTAssertTrue(invitation.existsOrAppears(timeout: 3))
        XCTAssertTrue(invitation.isHittable)
        invitation.tap()
        let connect = app.buttons["Connect to iCloud"]
        XCTAssertTrue(connect.existsOrAppears(timeout: 3))
        connect.tap()
        let keepOriginal = app.buttons["Keep Preview household on this device"]
        XCTAssertTrue(keepOriginal.existsOrAppears(timeout: 5))
        app.buttons["Not now"].tap()
        XCTAssertTrue(connect.existsOrAppears(timeout: 3))
        XCTAssertTrue(connect.isHittable)
        connect.tap()
        XCTAssertTrue(keepOriginal.existsOrAppears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your current home is Preview household. Its groceries will stay separate from the invited home."].exists)
        XCTAssertTrue(keepOriginal.isHittable)
        keepOriginal.tap()
        let done = app.navigationBars["Home invitations"].buttons["Done"]
        XCTAssertTrue(done.existsOrAppears(timeout: 3))
        done.tap()
        XCTAssertTrue(app.staticTexts["Waiting for your household"].existsOrAppears(timeout: 8))
        app.buttons["Choose a home"].tap()
        let openOriginal = app.buttons["Open Preview household on this device"]
        XCTAssertTrue(openOriginal.existsOrAppears(timeout: 3))
        XCTAssertTrue(openOriginal.isHittable)
        openOriginal.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 3))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 3))
        app.tabBars.buttons["Settings"].tap()
        openManageHomes(app)
        XCTAssertTrue(app.buttons["Return to iCloud homes"].existsOrAppears(timeout: 3))
        XCTAssertTrue(app.staticTexts["This home is saved on this device. Your iCloud homes stay separate."].exists)
    }

    private func openLegacyReview(_ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(app.buttons["shopping.settings.recovery"].exists)
        XCTAssertFalse(app.buttons["Review old cart entries"].exists)
        XCTAssertFalse(app.buttons["Saved personal carts"].exists)
        app.tabBars.buttons["Groceries"].tap()
        app.buttons["In cart (0)"].tap()
        XCTAssertTrue(app.navigationBars["My cart"].existsOrAppears(timeout: 3))
        let review = app.buttons["shopping.personalCart.legacyReview"]
        XCTAssertTrue(review.existsOrAppears(timeout: 5))
        XCTAssertTrue(review.isHittable)
        review.tap()
        XCTAssertTrue(app.navigationBars["Old cart entries"].existsOrAppears(timeout: 3))
    }

    private func openManageHomes(_ app: XCUIApplication) {
        let home = app.buttons["shopping.settings.homeDetails"]
        for _ in 0..<6 {
            if home.exists && home.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(home.isHittable)
        home.tap()
        if !app.navigationBars["Manage homes"].exists {
            let manage = app.buttons["shopping.home.manageHomes"]
            for _ in 0..<6 {
                if manage.exists && manage.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(manage.isHittable)
            manage.tap()
        }
        XCTAssertTrue(app.navigationBars["Manage homes"].existsOrAppears(timeout: 3))
    }

    private func launch(purchaseNotice: Bool = false, revoked: Bool = false, personalCart: Bool = true, unavailableSetup: Bool = false, activeHomes: Bool = false, pendingHomeCreation: Bool = false, pendingInvitation: Bool = false, homeAdoption: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        if homeAdoption { app.launchEnvironment["SHOPPING_UI_TEST_HOME_ADOPTION"] = "1" }
        if pendingInvitation { app.launchEnvironment["SHOPPING_UI_TEST_PENDING_INVITATION"] = "1" }
        if activeHomes { app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1" }
        if pendingHomeCreation { app.launchEnvironment["SHOPPING_UI_TEST_PENDING_HOME_CREATION"] = "1" }
        if personalCart { app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1" }
        if unavailableSetup { app.launchEnvironment["SHOPPING_UI_TEST_SETUP_UNAVAILABLE"] = "1" }
        if purchaseNotice { app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_NOTICE"] = "1" }
        if revoked { app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_REVOKED"] = "1" }
        app.launch()
        return app
    }

    private func groceryRow(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.grocery.row.", "Edit \(name)")).firstMatch
    }
}
