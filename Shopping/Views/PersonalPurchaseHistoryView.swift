import SwiftUI

struct PersonalPurchaseHistoryView: View {
    let cart: PersonalCartPresentation
    @State private var error: String?
    @State private var resultMessage: String?
    @State private var pendingRestoreIDs: Set<UUID> = []

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
                    if purchase.pendingPublication { Text("Saved purchase awaiting home processing").foregroundStyle(.secondary) }
                    if purchase.restored {
                        Text("Purchase undone").foregroundStyle(.secondary)
                    } else {
                        Button("Undo this purchase") { restore(purchase.id) }
                            .disabled(pendingRestoreIDs.contains(purchase.id))
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
        guard pendingRestoreIDs.insert(id).inserted else { return }
        let service = cart.service
        Task {
            defer { pendingRestoreIDs.remove(id) }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try service.restore(checkoutID: id)
                }.value
                resultMessage = "Restored \(result.purchasedCount) items; left \(result.skippedCount) unchanged. Other shoppers’ purchases and newer requests are retained."
                if result.pendingPublication { resultMessage? += " Saved undo awaiting home processing." }
                cart.refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { PersonalPurchaseHistoryView(cart: cart) } } }
#endif
