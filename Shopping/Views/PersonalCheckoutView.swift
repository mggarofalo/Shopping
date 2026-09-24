import SwiftUI

struct PersonalCheckoutView: View {
    let cart: PersonalCartPresentation
    let token: PersonalCheckoutToken
    var storeName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.shoppingToastCenter) private var toastCenter
    @State private var acknowledged: Set<UUID> = []
    @State private var error: String?

    private var requiredAcknowledgements: Set<UUID> {
        Set(token.captures.flatMap { $0.entry.purchaseNotices.map(\.receiptID) })
    }

    var body: some View {
        NavigationStack {
            List {
                Text("\(token.captures.count) items · \(storeName ?? (token.storeID == nil ? "All stores" : "Selected store"))")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(token.captures, id: \.entry.id) { capture in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(capture.entry.title)
                            Spacer()
                            if let quantity = capture.entry.quantity { Text("\(quantity)") }
                        }
                        ForEach(capture.entry.purchaseNotices, id: \.receiptID) { notice in
                            Toggle(isOn: Binding(
                                get: { acknowledged.contains(notice.receiptID) },
                                set: { if $0 { acknowledged.insert(notice.receiptID) } else { acknowledged.remove(notice.receiptID) } }
                            )) {
                                Text(notice.purchaserName.map { "Already purchased by \($0). Buy anyway" } ?? "Already purchased. Buy anyway")
                            }
                        }
                    }
                }
                Text("Only these captured items will be checked out. Changed items are kept for review.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Check out")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") { confirm() }
                        .disabled(token.captures.isEmpty || !requiredAcknowledgements.isSubset(of: acknowledged))
                }
            }
        }
    }

    private func confirm() {
        do {
            let result = try cart.service.checkout(token, buyAnywayReceiptIDs: acknowledged, operationID: token.id)
            cart.refresh()
            var message = "Checked out \(result.purchasedCount) items."
            if result.skippedCount > 0 { message += " Kept \(result.skippedCount) changed items." }
            if result.pendingPublication { message += " Household sync pending." }
            toastCenter?.show(message, duration: .attention)
            dismiss()
        } catch { self.error = error.localizedDescription; cart.refresh() }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in if let token = try? cart.service.prepareCheckout(tokens: cart.entries.map(\.token)) { PersonalCheckoutView(cart: cart, token: token) } } }
#endif
