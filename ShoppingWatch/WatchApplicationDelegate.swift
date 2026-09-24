import CloudKit
import Foundation
import WatchKit

extension Notification.Name {
    static let watchAcceptedShare = Notification.Name("ShoppingWatchAcceptedCloudShare")
}

final class WatchApplicationDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["SHOPPING_WATCH_FIXTURE"] == nil,
              environment["SHOPPING_WATCH_DURABLE_FIXTURE"] == nil,
              environment["XCTestConfigurationFilePath"] == nil else { return }
        #endif
        WKApplication.shared().registerForRemoteNotifications()
    }

    func userDidAcceptCloudKitShare(with cloudKitShareMetadata: CKShare.Metadata) {
        NotificationCenter.default.post(name: .watchAcceptedShare, object: nil,
            userInfo: ["metadata": cloudKitShareMetadata])
    }
}
