import SwiftUI

struct PersonalCartItemView: View {
    let cart: PersonalCartPresentation
    let entry: PersonalCartEntrySnapshot
    var storeID: UUID? = nil
    var storeName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var checkout: PersonalCheckoutSheet?

    private var current: PersonalCartEntrySnapshot { cart.entries.first { $0.id == entry.id } ?? entry }

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
                    if let quantity = current.quantity {
                        Stepper("\(quantity)", value: Binding(get: { quantity }, set: { setQuantity($0) }), in: 1...99)
                    }
                }
                if !current.purchaseNotices.isEmpty {
                    Section {
                        ForEach(current.purchaseNotices, id: \.receiptID) { notice in
                            Text(notice.purchaserName.map { "Already purchased by \($0)" } ?? "Already purchased")
                        }
                        Button("Buy anyway") { prepare() }
                    }
                }
                Button("Remove from my cart", role: .destructive) {
                    do { try cart.uncart(current); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            .navigationTitle("Cart item")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $checkout) { sheet in PersonalCheckoutView(cart: cart, token: sheet.token, storeName: sheet.storeName) }
            .alert("Couldn’t update cart", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func setQuantity(_ quantity: Int64?) {
        do { try cart.setQuantity(quantity, entry: current) }
        catch { self.error = error.localizedDescription }
    }

    private func prepare() {
        do { checkout = .init(token: try cart.service.prepareCheckout(tokens: [current.token], storeID: storeID), storeName: storeName) }
        catch { self.error = error.localizedDescription }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in if let entry = cart.entries.first { PersonalCartItemView(cart: cart, entry: entry) } } }
#endif
