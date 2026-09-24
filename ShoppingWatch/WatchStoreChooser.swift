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
                    HStack {
                        Text(store.name)
                        Spacer(minLength: 0)
                        if store.id == session.snapshot.selectedStoreID {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(session.isBusy)
                .accessibilityValue(store.id == session.snapshot.selectedStoreID ? "Selected" : "")
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
