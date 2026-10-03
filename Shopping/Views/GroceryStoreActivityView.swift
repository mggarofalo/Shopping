import SwiftUI
import UIKit

struct GroceryStoreShare: Identifiable {
    let id = UUID()
    let text: String
}

/// Present the same native activity sheet used by the app's invitation flow.
struct GroceryStoreActivityView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let share: GroceryStoreShare

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [share.text], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in dismiss() }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    GroceryStoreActivityView(share: GroceryStoreShare(text: "Milk\nBananas"))
}
