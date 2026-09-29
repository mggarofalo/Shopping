import CloudKit
import UIKit

/// SwiftUI keeps window ownership; this delegate forwards both system invitation routes.
final class ShoppingSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            HomeInvitationController.shared.receive(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        HomeInvitationController.shared.receive(metadata)
    }
}
