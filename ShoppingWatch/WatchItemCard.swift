import SwiftUI

struct WatchItemCard: View {
    let session: WatchShoppingSession
    let itemID: String
    @Environment(\.dismiss) private var dismiss
    @State private var draftQuantity: Int?
    @State private var hasLoadedDraft = false
    @ScaledMetric(relativeTo: .caption2) private var headerFontSize = 11

    var body: some View {
        List {
            if let item = session.snapshot.item(id: itemID) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.headline)
                    if let rule = item.rule {
                        Label(rule.title, systemImage: rule.symbol)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if item.isUrgent { Label("Urgent", systemImage: "exclamationmark").font(.caption2).foregroundStyle(.orange) }
                    if item.isOneTime { Text("One-time item").font(.caption2).foregroundStyle(.secondary) }
                    if !item.notes.isEmpty { Text(item.notes).font(.footnote) }
                    if let reason = item.unavailableReason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                }
                .listRowBackground(Color.clear)
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
                Section {
                    quantityControls(item: item)
                } header: {
                    Text(item.isInOwnCart ? "Your cart quantity" : "Quantity to buy")
                        .font(.system(size: headerFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
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
                }
            } else {
                Text("This item has changed. Return to the list to see the latest groceries.")
            }
        }
        .listStyle(.plain)
        .navigationTitle("Item")
        .safeAreaInset(edge: .bottom, spacing: 4) {
            if let item = addableItem {
                HStack {
                    Button {
                        Task {
                            if await session.perform(.add(token: item.commandToken, quantity: draftQuantity)) {
                                dismiss()
                            }
                        }
                    } label: {
                        Text("Add to cart").font(.caption2)
                    }
                    .buttonStyle(WatchCompactButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(session.isBusy)
                    .accessibilityLabel("Add to your cart")
                    .accessibilityIdentifier("watch.item.add")
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
                .background(.background)
            }
        }
        .ignoresSafeArea(.container, edges: addableItem == nil ? [] : .bottom)
        .task {
            if !hasLoadedDraft {
                draftQuantity = session.snapshot.item(id: itemID)?.quantity
                hasLoadedDraft = true
            }
        }
    }

    private var addableItem: WatchShoppingItem? {
        guard let item = session.snapshot.item(id: itemID), !item.isInOwnCart, item.canAdd else { return nil }
        return item
    }

    private func quantityControls(item: WatchShoppingItem) -> some View {
        let quantity = item.isInOwnCart ? item.quantity : draftQuantity
        let editable = !session.isBusy && (item.isInOwnCart ? item.canChangeQuantity : item.canAdd)
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button { setQuantity(max(1, (quantity ?? 1) - 1), item: item) } label: {
                    Image(systemName: "minus").frame(width: 24)
                }
                .disabled(!editable || quantity == nil || quantity == 1)
                .accessibilityLabel("Decrease your quantity")
                .accessibilityValue(quantity.map(String.init) ?? "Not specified")
                Text(quantity.map(String.init) ?? "—")
                    .font(.body).monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(quantity.map(String.init) ?? "Quantity not specified")
                Button { setQuantity(min(99, (quantity ?? 0) + 1), item: item) } label: {
                    Image(systemName: "plus").frame(width: 24)
                }
                .disabled(!editable || quantity == 99)
                .accessibilityLabel("Increase your quantity")
                .accessibilityValue(quantity.map(String.init) ?? "Not specified")
            }
            .buttonStyle(WatchCompactButtonStyle())
            if quantity != nil {
                Button("Clear quantity") { setQuantity(nil, item: item) }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .disabled(!editable)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
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
