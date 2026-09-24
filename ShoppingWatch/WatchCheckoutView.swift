import SwiftUI

struct WatchCheckoutView: View {
    let session: WatchShoppingSession
    let preview: WatchCheckoutPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Text("Check out \(preview.itemCountText)?").font(.headline)
            Text("Your cart · \(preview.storeName)").font(.footnote).foregroundStyle(.secondary)
            ForEach(preview.rows) { row in
                HStack {
                    Text(row.name)
                    Spacer(minLength: 4)
                    if let quantity = row.quantity { Text("\(quantity)").monospacedDigit() }
                }
            }
            Text("Only these captured items will be cleared. Changed items stay in your cart.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Clear \(preview.itemCountText)", role: .destructive) {
                Task { await session.confirmCheckout(preview) }
            }
            .disabled(session.isBusy)
            .accessibilityIdentifier("watch.checkout.confirm")
            Button("Cancel", role: .cancel) { dismiss() }
                .disabled(session.isBusy)
        }
        .navigationTitle("Check out")
        .interactiveDismissDisabled(session.isBusy)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        WatchCheckoutView(session: WatchPreviewService.previewSession(), preview: WatchPreviewService.previewCheckout)
    }
}
#endif
