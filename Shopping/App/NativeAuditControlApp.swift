#if DEBUG
import SwiftUI

// Temporary SHOPPING-131 calibration. Remove this entire file before integration.
// This App never constructs ShoppingApp, bootstrap, Core Data, or the app delegate.
struct NativeAuditControlApp: App {
    private let layout: NativeAuditControlView.Layout

    // App.main() constructs Self through init(), so consume only the explicit launch choice.
    init() {
        layout = Self.requestedLayout ?? .stack
    }

    static var requestedLayout: NativeAuditControlView.Layout? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["SHOPPING_UI_TEST_NATIVE_AUDIT_CONTROL"],
              let layout = NativeAuditControlView.Layout(rawValue: raw),
              let marker = environment["SHOPPING_UI_TEST_NATIVE_AUDIT_NONCE"],
              UUID(uuidString: marker) != nil,
              let path = environment["SHOPPING_UI_TEST_STORE_PATH"],
              path.hasPrefix("/"), path.hasSuffix(".sqlite"), path.contains(marker) else { return nil }
        return layout
    }

    var body: some Scene {
        WindowGroup { NativeAuditControlView(layout: layout) }
    }
}

#endif
