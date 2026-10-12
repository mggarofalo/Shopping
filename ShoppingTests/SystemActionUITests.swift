import XCTest

final class SystemActionUITests: XCTestCase {


    func testHomeScreenAddOpensCatalogAddWithoutChangingList() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        app.buttons["Recently cleared"].tap()
        XCTAssertTrue(app.navigationBars["Recently cleared"].existsOrAppears(timeout: 5))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Milk & Bananas"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        icon.press(forDuration: 1.2)
        let action = springboard.buttons["Add item"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let menu = XCTAttachment(screenshot: springboard.screenshot())
        menu.name = "Add and Search Home Screen actions"
        menu.lifetime = .keepAlways
        add(menu)
        XCTAssertTrue(springboard.buttons["Search catalog"].exists)
        XCTAssertFalse(springboard.buttons["Open grocery list"].exists)
        action.tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].existsOrAppears(timeout: 10))
        XCTAssertTrue(app.searchFields["Search catalog"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.existsOrAppears(timeout: 3))
        // Active native search hides the sheet toolbar until search is dismissed.
        let closeSearch = app.buttons["Close"]
        if closeSearch.existsOrAppears(timeout: 2) {
            closeSearch.tap()
        } else {
            app.buttons["Cancel"].tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["shopping.grocery.catalogCancel"].existsOrAppears(timeout: 3))
        app.buttons["shopping.grocery.catalogCancel"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
    }
    func testSettingsFindsShortcutsAndSystemAddResolvesAnExistingItem() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        let link = app.buttons["shopping.siri.shortcuts"]
        for _ in 0..<3 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.isHittable)
        link.tap()
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        XCTAssertTrue(shortcuts.wait(for: .runningForeground, timeout: 10))
        let welcome = shortcuts.buttons["Continue"]
        if welcome.exists { welcome.tap() }
        XCTAssertTrue(shortcuts.navigationBars["Milk & Bananas"].existsOrAppears(timeout: 10))
        XCTAssertTrue(shortcuts.staticTexts["Add item"].exists)
        XCTAssertTrue(shortcuts.staticTexts["Search catalog"].exists)
        XCTAssertFalse(shortcuts.staticTexts["Open grocery list"].exists)
        let discovered = XCTAttachment(screenshot: shortcuts.screenshot())
        discovered.name = "Milk & Bananas actions in system Shortcuts"
        discovered.lifetime = .keepAlways
        add(discovered)
        shortcuts.otherElements["Add item"].buttons["plus"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let name = springboard.textFields["Item name"]
        XCTAssertTrue(name.existsOrAppears(timeout: 15))
        name.typeText("Bananas")
        XCTAssertEqual(name.value as? String, "Bananas")
        // The keyboard also has a Done identifier, but its label is lowercase.
        springboard.buttons.matching(NSPredicate(format: "label == %@", "Done")).element.tap()
        XCTAssertTrue(springboard.staticTexts["Bananas is already on your grocery list."].existsOrAppears(timeout: 10))
        let result = XCTAttachment(screenshot: springboard.screenshot())
        result.name = "System Add resolves catalog without duplicating an existing need"
        result.lifetime = .keepAlways
        add(result)
        springboard.buttons.matching(NSPredicate(format: "label == %@", "Done")).element.tap()
        XCTAssertTrue(springboard.staticTexts["Bananas is already on your grocery list."].waitForNonExistence(timeout: 5))
        // Unknown text must cross the real system foreground-continuation boundary.
        shortcuts.otherElements["Add item"].buttons["plus"].tap()
        XCTAssertTrue(name.existsOrAppears(timeout: 15))
        name.typeText("Space pears")
        XCTAssertEqual(name.value as? String, "Space pears")
        springboard.buttons.matching(NSPredicate(format: "label == %@", "Done")).element.tap()
        let continueInApp = springboard.buttons["Continue"]
        XCTAssertTrue(continueInApp.existsOrAppears(timeout: 10))
        continueInApp.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let reviewMessage = springboard.staticTexts["Review Space pears in the app, then save and add it."]
        XCTAssertTrue(reviewMessage.existsOrAppears(timeout: 10))
        springboard.buttons.matching(NSPredicate(format: "label == %@", "Done")).element.tap()
        XCTAssertTrue(reviewMessage.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 10))
        XCTAssertEqual(app.textFields["shopping.catalog.name"].value as? String, "Space pears")
        let handoff = XCTAttachment(screenshot: app.screenshot())
        handoff.name = "System unknown item continues into prefilled editor"
        handoff.lifetime = .keepAlways
        add(handoff)
        app.navigationBars["New catalog item"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].waitForNonExistence(timeout: 5))
    }

}
