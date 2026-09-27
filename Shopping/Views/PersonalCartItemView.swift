import SwiftUI

struct PersonalCartItemView: View {
    let cart: PersonalCartPresentation
    let entry: PersonalCartEntrySnapshot
    var storeID: UUID? = nil
    var storeName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var checkout: PersonalCheckoutSheet?
    @State private var isPreparingCheckout = false
    @State private var isRemoving = false

    private var current: PersonalCartEntrySnapshot { cart.entries.first { $0.id == entry.id } ?? entry }
    private var quantityPending: Bool { cart.isQuantityTransitionPending(current.id) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(current.title).font(.headline)
                    if !current.notes.isEmpty { Text(current.notes) }
                    if !current.demandAvailable { Text("The original request is no longer available. Your cart entry is saved.").foregroundStyle(.secondary) }
                }
                Section("My quantity") {
                    Toggle("Specify quantity", isOn: Binding(
                        get: { current.quantity != nil },
                        set: { setQuantity($0 ? 1 : nil) }
                    ))
                    .disabled(quantityPending)
                    if let quantity = current.quantity {
                        Stepper("\(quantity)", value: Binding(get: { quantity }, set: { setQuantity($0) }), in: 1...99)
                            .disabled(quantityPending)
                    }
                }
                if !current.purchaseNotices.isEmpty {
                    Section {
                        ForEach(current.purchaseNotices, id: \.receiptID) { notice in
                            Text(notice.purchaserName.map { "Already purchased by \($0)" } ?? "Already purchased")
                        }
                        Button("Buy anyway") { prepare() }
                            .disabled(quantityPending || isPreparingCheckout)
                    }
                }
                Button("Remove from my cart", role: .destructive) {
                    guard !isRemoving else { return }
                    isRemoving = true
                    let entry = current
                    Task {
                        defer { isRemoving = false }
                        do { try await cart.uncart(entry); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(isRemoving || quantityPending || cart.isCartTransitionPending(current.needID))
            }
            .navigationTitle("Cart item")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }
                .disabled(isRemoving || quantityPending || isPreparingCheckout || cart.isCartTransitionPending(current.needID)) } }
            .interactiveDismissDisabled(isRemoving || quantityPending || isPreparingCheckout || cart.isCartTransitionPending(current.needID))
            .sheet(item: $checkout) { sheet in PersonalCheckoutView(cart: cart, token: sheet.token, storeName: sheet.storeName) }
            .alert("Couldn’t update cart", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func setQuantity(_ quantity: Int64?) {
        let entry = current
        Task {
            do { try await cart.setQuantity(quantity, entry: entry) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func prepare() {
        guard !isPreparingCheckout, !quantityPending else { return }
        isPreparingCheckout = true
        let service = cart.service
        let entryToken = current.token
        let storeID = self.storeID
        Task {
            defer { isPreparingCheckout = false }
            do {
                let token = try await Task.detached(priority: .userInitiated) {
                    try service.prepareCheckout(tokens: [entryToken], storeID: storeID)
                }.value
                checkout = .init(token: token, storeName: storeName)
            } catch { self.error = error.localizedDescription }
        }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in if let entry = cart.entries.first { PersonalCartItemView(cart: cart, entry: entry) } } }
#endif
