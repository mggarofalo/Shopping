import XCTest

final class PersonalCartUITests: XCTestCase {
    func testFirstHomeCreatesInOneTapAndRestoresAfterRelaunch() {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1"
        app.launch()
        let create = app.buttons["shopping.home.createFirst"]
        XCTAssertTrue(create.existsOrAppears(timeout: 8))
        create.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        let scope = app.buttons["shopping.home.scope"]
        XCTAssertTrue(scope.existsOrAppears(timeout: 3))
        XCTAssertTrue((scope.value as? String)?.contains("My Home") == true)
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        XCTAssertTrue((scope.value as? String)?.contains("My Home") == true)
        XCTAssertFalse(create.exists)
    }

    func testAcceptedInvitationOpensExactHomeWithoutAppJoinTap() {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1"
        app.launchEnvironment["SHOPPING_UI_TEST_ACCEPTED_INVITATION"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Invitation"].existsOrAppears(timeout: 5))
        XCTAssertFalse(app.buttons["Join Home"].exists, "Native acceptance already recorded join intent")
        let selected = app.buttons["shopping.home.scope"]
        XCTAssertTrue(selected.existsOrAppears(timeout: 8))
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (selected.value as? String)?.contains("Second home") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 8), .completed)
        XCTAssertFalse(groceryRow("Granola", app: app).exists)
        openManageHomes(app)
        XCTAssertTrue((homeChoice("Second home", app: app).value as? String)?.contains("Selected") == true)
        XCTAssertTrue(homeChoice("Preview household", app: app).exists)
    }

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
        XCTAssertTrue(app.navigationBars["Home Settings"].waitForExistence(timeout: 3))
        app.buttons["shopping.home.useICloud"].tap()
        XCTAssertTrue(app.staticTexts["Your iCloud account is temporarily unavailable. Try again later."].existsOrAppears(timeout: 8))
        XCTAssertTrue(app.navigationBars["Home Settings"].exists)
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
        XCTAssertTrue(app.buttons["shopping.home.savedCarts"].waitForExistence(timeout: 8))
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.buttons["shopping.home.savedCarts"].waitForExistence(timeout: 8))
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
        let notNow = app.buttons["shopping.invitation.notNow"]
        XCTAssertTrue(notNow.existsOrAppears(timeout: 8))
        XCTAssertTrue(app.navigationBars["Invitation"].exists)
        notNow.tap()
        XCTAssertTrue(notNow.waitForNonExistence(timeout: 5))
        let choose = app.buttons["shopping.home.choose"]
        XCTAssertTrue(choose.existsOrAppears(timeout: 5), "A pending invite must not silently select a home")
        choose.tap()
        XCTAssertTrue(app.navigationBars["Homes"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.home.choice.", "Preview household")).firstMatch.existsOrAppears(timeout: 5))
        let original = homeChoice("Preview household", app: app)
        XCTAssertTrue(original.existsOrAppears(timeout: 3))
        original.tap()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        openManageHomes(app)
        let deferred = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "shopping.home.openInvitation.")).firstMatch
        XCTAssertTrue(deferred.existsOrAppears(timeout: 3))
        app.buttons["Done"].tap()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_PENDING_INVITATION")
        app.launch()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        XCTAssertFalse(notNow.exists, "Dismissed join must not automatically reopen")
        openManageHomes(app)
        XCTAssertTrue(deferred.existsOrAppears(timeout: 3))
        deferred.tap()
        XCTAssertTrue(app.navigationBars["Invitation"].existsOrAppears(timeout: 5))
        XCTAssertTrue(notNow.existsOrAppears(timeout: 3))
        let state = app.staticTexts["shopping.invitation.state"]
        XCTAssertTrue(state.existsOrAppears(timeout: 3))
        XCTAssertNotEqual(state.label, "Invitation unavailable")
        XCTAssertFalse(app.buttons["Join Home"].exists)
        notNow.tap()
        XCTAssertTrue(notNow.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        XCTAssertFalse(notNow.exists, "Reopened join must stay deferred after a second Not Now")
        openManageHomes(app)
        XCTAssertTrue(deferred.existsOrAppears(timeout: 3))
    }

    func testSwitchExistingHomesPreservesOriginalGroceriesAfterRelaunch() {
        let app = launch(activeHomes: true, secondHome: true)
        XCTAssertTrue(app.buttons["shopping.home.choose"].existsOrAppears(timeout: 8))
        app.buttons["shopping.home.choose"].tap()
        let originalChoice = homeChoice("Preview household", app: app)
        XCTAssertTrue(originalChoice.existsOrAppears(timeout: 5))
        originalChoice.tap()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        groceryRow("Granola", app: app).swipeLeft()
        let cartAction = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shopping.checklist.cart.")).firstMatch
        XCTAssertTrue(cartAction.existsOrAppears(timeout: 3))
        cartAction.tap()
        XCTAssertTrue(app.staticTexts["Granola moved to In cart."].waitForNonExistence(timeout: 5))
        openManageHomes(app)
        XCTAssertTrue(app.buttons["shopping.home.create"].exists)
        XCTAssertFalse(app.textFields["shopping.home.name"].exists)
        let second = homeChoice("Second home", app: app)
        XCTAssertTrue(second.existsOrAppears(timeout: 3))
        second.tap()
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
        XCTAssertTrue(homeChoice("Second home", app: app).existsOrAppears(timeout: 3))
        XCTAssertTrue((homeChoice("Second home", app: app).value as? String)?.contains("Selected") == true)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 8))
        XCTAssertFalse(groceryRow("Granola", app: app).exists)
        openManageHomes(app)
        XCTAssertTrue(homeChoice("Second home", app: app).existsOrAppears(timeout: 3))
        XCTAssertTrue((homeChoice("Second home", app: app).value as? String)?.contains("Selected") == true)
        let original = homeChoice("Preview household", app: app)
        XCTAssertTrue(original.existsOrAppears(timeout: 3))
        original.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
        XCTAssertTrue(app.buttons["In cart (1)"].existsOrAppears(timeout: 5))
        app.buttons["In cart (1)"].tap()
        XCTAssertTrue(app.navigationBars["My cart"].existsOrAppears(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "shopping.personalCart.item.", "Granola")).element.existsOrAppears(timeout: 5))
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

    func testLocalHomeRemainsAvailableInHomesPicker() {
        let app = launch(personalCart: false, homeAdoption: true)
        let notNow = app.buttons["shopping.invitation.notNow"]
        XCTAssertTrue(notNow.existsOrAppears(timeout: 8))
        notNow.tap()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        openManageHomes(app)
        let local = app.buttons["shopping.home.retainedLocal"]
        XCTAssertTrue(local.existsOrAppears(timeout: 3))
        XCTAssertTrue((local.value as? String)?.contains("On This iPhone") == true)
        app.buttons["shopping.home.settings"].tap()
        XCTAssertTrue(app.navigationBars["Home Settings"].existsOrAppears(timeout: 3))
        XCTAssertTrue(app.buttons["shopping.home.openICloud"].exists)
        XCTAssertFalse(app.buttons["shopping.home.useICloud"].exists)
        XCTAssertFalse(app.staticTexts["Copies this home to iCloud. Your local home stays saved."].exists)
        app.navigationBars["Home Settings"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        app.launch()
        XCTAssertTrue(groceryRow("Granola", app: app).existsOrAppears(timeout: 8))
        openManageHomes(app)
        XCTAssertTrue(local.existsOrAppears(timeout: 3))
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
        let scope = app.buttons["shopping.home.scope"]
        XCTAssertTrue(scope.existsOrAppears(timeout: 5))
        XCTAssertTrue(scope.isHittable)
        scope.tap()
        XCTAssertTrue(app.navigationBars["Homes"].existsOrAppears(timeout: 3))
    }

    private func homeChoice(_ name: String, app: XCUIApplication) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
            "shopping.home.choice.", name))
        XCTAssertEqual(matches.count, 1, "The isolated fixture must identify one exact home row")
        return matches.element(boundBy: 0)
    }

    private func launch(purchaseNotice: Bool = false, revoked: Bool = false, personalCart: Bool = true, unavailableSetup: Bool = false, activeHomes: Bool = false, secondHome: Bool = false, pendingInvitation: Bool = false, homeAdoption: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        if homeAdoption { app.launchEnvironment["SHOPPING_UI_TEST_HOME_ADOPTION"] = "1" }
        if pendingInvitation { app.launchEnvironment["SHOPPING_UI_TEST_PENDING_INVITATION"] = "1" }
        if activeHomes { app.launchEnvironment["SHOPPING_UI_TEST_ACTIVE_HOMES"] = "1" }
        if secondHome { app.launchEnvironment["SHOPPING_UI_TEST_SECOND_HOME"] = "1" }
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
