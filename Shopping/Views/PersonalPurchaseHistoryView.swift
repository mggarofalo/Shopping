import SwiftUI

struct PersonalPurchaseHistoryView: View {
    let cart: PersonalCartPresentation
    @State private var error: String?
    @State private var resultMessage: String?

    var body: some View {
        List {
            if cart.history.isEmpty { Text("No purchases yet").foregroundStyle(.secondary) }
            ForEach(cart.history) { purchase in
                Section {
                    ForEach(purchase.entries) { entry in
                        HStack {
                            Text(entry.title)
                            if purchase.restoredNeedIDs.contains(entry.needID) {
                                Spacer()
                                Text("Undone").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if purchase.pendingPublication { Text("Household sync pending").foregroundStyle(.secondary) }
                    if purchase.restored {
                        Text("Purchase undone").foregroundStyle(.secondary)
                    } else {
                        Button("Undo this purchase") { restore(purchase.id) }
                    }
                } header: { Text(purchase.createdAt, style: .date) }
            }
            if let message = resultMessage { Text(message) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("My purchases")
        .onAppear { cart.refresh() }
        .alert("Couldn’t undo purchase", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func restore(_ id: UUID) {
        do {
            let result = try cart.service.restore(checkoutID: id)
            resultMessage = "Restored \(result.purchasedCount) items; left \(result.skippedCount) unchanged. Other shoppers’ purchases and newer requests are retained."
            if result.pendingPublication { resultMessage? += " Household sync pending." }
            cart.refresh()
        } catch { self.error = error.localizedDescription }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { PersonalPurchaseHistoryView(cart: cart) } } }
#endif
