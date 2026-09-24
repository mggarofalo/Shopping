import SwiftUI

struct WatchCheckoutButton: View {
    let session: WatchShoppingSession

    var body: some View {
        Button { Task { await session.prepareCheckout() } } label: {
            Text("Check out").font(.caption)
        }
        .disabled(!session.snapshot.canCheckout || session.snapshot.selectedStore == nil || session.snapshot.cartCount == 0 || session.isBusy)
        .accessibilityIdentifier("watch.checkout.open")
    }
}

#if DEBUG
#Preview { WatchCheckoutButton(session: WatchPreviewService.previewSession()) }
#endif
