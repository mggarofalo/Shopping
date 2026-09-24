import SwiftUI

struct WatchItemCard: View {
    let session: WatchShoppingSession
    let itemID: String
    @Environment(\.dismiss) private var dismiss
    @State private var draftQuantity: Int?
    @State private var hasLoadedDraft = false

    var body: some View {
        List {
            if let item = session.snapshot.item(id: itemID) {
                Text(item.name).font(.headline)
                if let rule = item.rule { Label(rule.title, systemImage: rule.symbol).font(.footnote) }
                if item.isUrgent { Label("Urgent", systemImage: "exclamationmark").foregroundStyle(.orange) }
                if item.isOneTime { Text("One-time item").font(.footnote) }
                if !item.notes.isEmpty { Text(item.notes).font(.footnote) }
                if let reason = item.unavailableReason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                if let notice = item.purchasedNotice {
                    Section {
                        Text(notice).font(.footnote)
                        if item.canBuyAnyway {
                            Button("Buy anyway") {
                                Task { await session.perform(.buyAnyway(token: item.commandToken)) }
                            }
                            .disabled(session.isBusy)
                            .accessibilityIdentifier("watch.item.buyAnyway")
                        }
                    }
                }
                Section(item.isInOwnCart ? "Your cart quantity" : "Quantity to buy") {
                    quantityControls(item: item)
                }
                if !item.otherCarts.isEmpty {
                    Section("Other shoppers") {
                        ForEach(item.otherCarts) { presence in
                            Text(presence.quantity.map { "\(presence.shopperName): \($0) in cart" }
                                ?? "\(presence.shopperName) has this in their cart")
                                .font(.footnote)
                        }
                        Text("Presence may be out of date.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if item.isInOwnCart && item.canRemove {
                    Button("Remove from your cart", role: .destructive) {
                        Task {
                            await session.perform(.remove(token: item.commandToken))
                            if session.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(session.isBusy)
                    .accessibilityIdentifier("watch.item.remove")
                } else if !item.isInOwnCart && item.canAdd {
                    Button("Add to your cart") {
                        Task {
                            await session.perform(.add(token: item.commandToken, quantity: draftQuantity))
                        }
                    }
                    .disabled(session.isBusy)
                    .accessibilityIdentifier("watch.item.add")
                }
            } else {
                Text("This item has changed. Return to the list to see the latest groceries.")
            }
        }
        .navigationTitle("Item")
        .task {
            if !hasLoadedDraft {
                draftQuantity = session.snapshot.item(id: itemID)?.quantity
                hasLoadedDraft = true
            }
        }
    }

    private func quantityControls(item: WatchShoppingItem) -> some View {
        let quantity = item.isInOwnCart ? item.quantity : draftQuantity
        let editable = !session.isBusy && (item.isInOwnCart ? item.canChangeQuantity : item.canAdd)
        return VStack(spacing: 4) {
            Text(quantity.map(String.init) ?? "Not specified").monospacedDigit()
            HStack {
                Button { setQuantity(max(1, (quantity ?? 1) - 1), item: item) } label: {
                    Image(systemName: "minus").frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!editable || quantity == nil || quantity == 1)
                .accessibilityLabel("Decrease your quantity")
                Button { setQuantity(min(99, (quantity ?? 0) + 1), item: item) } label: {
                    Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!editable || quantity == 99)
                .accessibilityLabel("Increase your quantity")
            }
            .buttonStyle(.bordered)
            if quantity != nil {
                Button("Clear quantity") { setQuantity(nil, item: item) }
                    .font(.footnote).disabled(!editable)
            }
        }
    }

    private func setQuantity(_ quantity: Int?, item: WatchShoppingItem) {
        if item.isInOwnCart {
            Task { await session.perform(.setQuantity(token: item.commandToken, quantity: quantity)) }
        } else {
            draftQuantity = quantity
        }
    }
}

#if DEBUG
#Preview("Purchase notice") {
    NavigationStack {
        WatchItemCard(session: WatchPreviewService.previewSession(), itemID: "milk")
    }
}
#endif
