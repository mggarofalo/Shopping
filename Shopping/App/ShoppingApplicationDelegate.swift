import UIKit

final class ShoppingApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["SHOPPING_UI_TEST_STORE_PATH"] == nil,
              environment["SHOPPING_UI_TEST_PERSISTENCE_FAILURE"] == nil,
              environment["XCTestConfigurationFilePath"] == nil else { return true }
        #endif
        // Silent CloudKit delivery does not request permission for visible alerts.
        application.registerForRemoteNotifications()
        return true
    }
}
