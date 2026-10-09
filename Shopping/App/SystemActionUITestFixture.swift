#if DEBUG
import Foundation

/// Exercises the production foreground handoff with an isolated UI-test store.
@MainActor
enum SystemActionUITestFixture {
    static func deliver(runtime: ShoppingApplicationRuntime, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let path = environment["SHOPPING_UI_TEST_STORE_PATH"], !path.isEmpty,
              let name = environment["SHOPPING_UI_TEST_NEW_CATALOG_NAME"], !name.isEmpty else { return }
        do {
            let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
            try context.createInApp(name: name)
        } catch { runtime.actions.message = error.localizedDescription }
    }
}
#endif
