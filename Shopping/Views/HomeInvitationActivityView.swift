import SwiftUI
import UIKit

/// Only the one-time URL is handed to the ordinary system share sheet. Passing a
/// CKShare here would expose collaboration controls outside our lifecycle commands.
struct HomeInvitationActivityView: UIViewControllerRepresentable {
    let delivery: HomeInvitationDelivery
    let onPresented: () -> Void
    let onFinished: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = PresentedActivityController(activityItems: [delivery.url], applicationActivities: nil)
        controller.didPresent = onPresented
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onFinished() }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    private final class PresentedActivityController: UIActivityViewController {
        var didPresent: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didPresent?()
            didPresent = nil
        }
    }
}
