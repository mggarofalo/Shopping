import SwiftUI

@main
struct ShoppingWatchApp: App {
    @State private var session: WatchShoppingSession

    init() {
        #if DEBUG
        let fixture = ProcessInfo.processInfo.environment["SHOPPING_WATCH_FIXTURE"]
        let service: any WatchShoppingService = fixture.map { WatchPreviewService(scenario: $0) }
            ?? UnavailableWatchShoppingService()
        #else
        let service: any WatchShoppingService = UnavailableWatchShoppingService()
        #endif
        _session = State(initialValue: WatchShoppingSession(service: service))
    }

    var body: some Scene {
        WindowGroup { WatchShoppingView(session: session) }
    }
}
