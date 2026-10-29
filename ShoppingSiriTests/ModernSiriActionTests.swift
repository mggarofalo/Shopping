import XCTest
import AppIntentsTesting

final class ModernSiriActionTests: XCTestCase {
    @MainActor
    func testModernSiriActionReturnsSavedEntityThroughSystemExecution() async throws {
        continueAfterFailure = false
        _ = launch()
        let definitions = IntentDefinitions(bundleIdentifier: "com.mggarofalo.shopping")
        let lists = try await definitions.entities["GroceryListEntity"].entities(matching: "my shopping list")
        XCTAssertEqual(lists.count, 1)
        let list = try XCTUnwrap(lists.first)
        let alternate = try await definitions.entities["GroceryListEntity"].entities(matching: "the shopping list")
        XCTAssertEqual(alternate.map(\.identifier), [list.identifier])
        let action = definitions.intents["AddSpokenGroceryIntent"].makeIntent(title: "Café au lait", list: list)
        let first = try await action.run()
        let entity: AnyAppEntity = try first.value
        let title: String = try entity.title
        XCTAssertEqual(title, "Café au lait")
        let repeated = try await action.run()
        let duplicate: AnyAppEntity = try repeated.value
        XCTAssertEqual(duplicate.identifier, entity.identifier)
    }

    /// SHOPPING-258: Siri runs the action with the app in the background. An unknown
    /// name must bring the prefilled editor forward promptly, finish without a saved
    /// reminder, and leave nothing pending that blocks the next request.
    @MainActor
    func testUnknownSpokenNameHandsOffToEditorWithoutBlockingLaterRequests() async throws {
        continueAfterFailure = false
        let app = launch()
        let definitions = IntentDefinitions(bundleIdentifier: "com.mggarofalo.shopping")
        let lists = try await definitions.entities["GroceryListEntity"].entities(matching: "my shopping list")
        let list = try XCTUnwrap(lists.first)
        for appName in ["Milk and Bananas", "Milk & Bananas"] {
            let named = try await definitions.entities["GroceryListEntity"].entities(matching: appName)
            XCTAssertEqual(named.map(\.identifier), [list.identifier], appName)
        }
        let add = definitions.intents["AddSpokenGroceryIntent"]

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let handoff = try await runWithinBound(add.makeIntent(title: "Ground beef", list: list))
        XCTAssertThrowsError(try handoff.value as AnyAppEntity, "An unsaved item has no reminder entity")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 10))
        XCTAssertEqual(app.textFields["shopping.catalog.name"].value as? String, "Ground beef")
        dismissEditor(in: app)

        let known = try await runWithinBound(add.makeIntent(title: "Café au lait", list: list))
        let saved: AnyAppEntity = try known.value
        let title: String = try saved.title
        XCTAssertEqual(title, "Café au lait")

        _ = try await runWithinBound(add.makeIntent(title: "Sandwich bread", list: list))
        XCTAssertTrue(app.navigationBars["New catalog item"].existsOrAppears(timeout: 10))
        XCTAssertEqual(app.textFields["shopping.catalog.name"].value as? String, "Sandwich bread")
        dismissEditor(in: app)
    }

    /// Cancel saves nothing. The handoff opens the editor from the Add sheet; a later
    /// request waits behind any open sheet rather than dismissing the user's work.
    @MainActor
    private func dismissEditor(in app: XCUIApplication) {
        app.navigationBars["New catalog item"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["New catalog item"].waitForNonExistence(timeout: 5))
        app.buttons["shopping.grocery.catalogCancel"].tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "inactiveCatalogSuggestion"
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        return app
    }

    /// The system connection abandons a stuck action after about 35 seconds; anything
    /// slower than this bound would leave Siri spinning on a device.
    private func runWithinBound(_ intent: AnyAppIntent, seconds: Double = 20) async throws -> ResolvedIntentResult {
        let started = ContinuousClock.now
        let result = try await intent.run()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(seconds), "Siri action exceeded its response bound")
        return result
    }
}
