import SwiftUI

struct WatchStoreChooser: View {
    let session: WatchShoppingSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let status = session.snapshot.statusMessage {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            if session.snapshot.stores.isEmpty {
                Text("No stores available").font(.footnote)
            }
            ForEach(session.snapshot.stores) { store in
                Button {
                    Task {
                        await session.reload(storeID: store.id)
                        if session.snapshot.selectedStoreID == store.id { dismiss() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(store.name)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if store.id == session.snapshot.selectedStoreID {
                            Image(systemName: "checkmark").font(.caption2).accessibilityHidden(true)
                        }
                        HStack(spacing: 6) {
                            Label("\(store.mustBuyCount)", systemImage: "lock.fill")
                            Label("\(store.canBuyCount)", systemImage: "lock.open")
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                }
                .disabled(session.isBusy)
                .accessibilityLabel(store.name)
                .accessibilityValue("\(store.id == session.snapshot.selectedStoreID ? "Selected. " : "")\(store.mustBuyCount) only buy here, \(store.canBuyCount) can buy here")
                .accessibilityIdentifier("watch.store.\(store.id)")
            }
            if session.snapshot.cartCount > 0 {
                NavigationLink("Your cart") { WatchCartView(session: session) }
            }
            NavigationLink("Recently cleared") { WatchRecoveryView(session: session) }
        }
        .navigationTitle("Stores")
    }
}

#if DEBUG
#Preview { NavigationStack { WatchStoreChooser(session: WatchShoppingSession(service: WatchPreviewService())) } }
#endif
