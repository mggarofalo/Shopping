import SwiftUI
import WatchKit

@main
struct ShoppingWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchApplicationDelegate.self) private var applicationDelegate
    @State private var session: WatchShoppingSession

    init() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let service: any WatchShoppingService
        if environment["SHOPPING_WATCH_DURABLE_FIXTURE"] != nil {
            do {
                guard let fixture = try WatchPersistentTestFixture.makeIfRequested() else {
                    throw CocoaError(.coderInvalidValue)
                }
                service = fixture
            } catch {
                service = UnavailableWatchShoppingService(message: "The test store could not be opened: \(error.localizedDescription)")
            }
        } else if let fixture = environment["SHOPPING_WATCH_FIXTURE"] {
            service = WatchPreviewService(scenario: fixture)
        } else {
            service = PersistentWatchShoppingService.production()
        }
        #else
        let service: any WatchShoppingService = PersistentWatchShoppingService.production()
        #endif
        _session = State(initialValue: WatchShoppingSession(service: service))
    }

    var body: some Scene {
        WindowGroup { WatchShoppingView(session: session) }
    }
}
