import Foundation
import XCTest

final class CloudConfigurationTests: XCTestCase {
    func testPackagedAppContainsCloudConfigurationAndNotificationCapability() {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "ShoppingCloudKitContainerIdentifier") as? String,
                       "iCloud.com.mggarofalo.shopping")
        #if DEBUG
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "ShoppingCloudKitEnvironment") as? String, "Development")
        #else
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "ShoppingCloudKitEnvironment") as? String, "Production")
        #endif
        #if os(watchOS)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CKSharingSupported") as? Bool, true)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "WKRunsIndependentlyOfCompanionApp") as? Bool, true)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String,
                       "com.mggarofalo.shopping")
        #else
        let backgroundModes = bundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertTrue(backgroundModes?.contains("remote-notification") == true)
        #endif
    }
}
