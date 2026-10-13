import XCTest
import AppIntentsTesting

final class ModernSiriActionTests: XCTestCase {
    @MainActor
    func testModernSiriActionReturnsSavedEntityThroughSystemExecution() async throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = directory.appendingPathComponent("Shopping.sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "inactiveCatalogSuggestion"
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
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
}
