import CloudKit
import UIKit

/// SwiftUI keeps window ownership; this delegate forwards both system invitation routes.
final class ShoppingSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcut = connectionOptions.shortcutItem { handle(shortcut) }
        if let metadata = connectionOptions.cloudKitShareMetadata {
            HomeInvitationController.shared.receive(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(handle(shortcutItem))
    }

    @discardableResult
    private func handle(_ shortcut: UIApplicationShortcutItem) -> Bool {
        guard let destination = ShoppingActionDestination(shortcutType: shortcut.type) else { return false }
        do { try ShoppingApplicationRuntime.shared.request(destination) }
        catch { ShoppingApplicationRuntime.shared.actions.message = error.localizedDescription }
        return true
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        HomeInvitationController.shared.receive(metadata)
    }
}
