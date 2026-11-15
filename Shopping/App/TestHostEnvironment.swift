import Foundation

/// Unit tests host the app, and UI tests launch it with a fixture store. System side
/// effects such as push registration and Siri donations stay off in both.
enum TestHostEnvironment {
    static func isActive(_ environment: [String: String]) -> Bool {
        environment["SHOPPING_UI_TEST_STORE_PATH"] != nil
            || environment["SHOPPING_UI_TEST_PERSISTENCE_FAILURE"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
    }
}
