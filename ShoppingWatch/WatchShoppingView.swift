import SwiftUI

struct WatchShoppingView: View {
    @Bindable var session: WatchShoppingSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .sheet(item: $session.sheet) { sheet in
                    NavigationStack {
                        switch sheet {
                        case .stores: WatchStoreChooser(session: session)
                        case .checkout(let preview): WatchCheckoutView(session: session, preview: preview)
                        case .result(let result): WatchResultView(result: result)
                        }
                    }
                    .modifier(WatchShoppingErrorPresenter(session: session, inSheet: true))
                }
        }
        .modifier(WatchShoppingErrorPresenter(session: session, inSheet: false))
        .task { await session.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.reload() } }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.snapshot.availability {
        case .loading:
            ProgressView("Loading groceries")
        case .setupRequired(let message):
            unavailable(title: "Set up Shopping", message: message, symbol: "iphone.and.arrow.forward")
        case .unavailable(let message):
            unavailable(title: "Groceries unavailable", message: message, symbol: "exclamationmark.icloud")
        case .ready:
            if let store = session.snapshot.selectedStore {
                groceries(store: store)
            } else {
                WatchStoreChooser(session: session)
            }
        }
    }

    private func unavailable(title: String, message: String, symbol: String) -> some View {
        List {
            Label(title, systemImage: symbol).font(.headline)
            Text(message).font(.footnote)
            Button("Try again") { Task { await session.reload() } }
                .disabled(session.isBusy)
        }
        .listStyle(.plain)
    }

    private func groceries(store: WatchStore) -> some View {
        List {
            if session.snapshot.grocerySections.isEmpty {
                Text("Nothing to get here").foregroundStyle(.secondary)
            }
            WatchItemSections(session: session, sections: session.snapshot.grocerySections)
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 4) {
                Button { session.sheet = .stores } label: {
                    HStack(spacing: 4) {
                        Text(store.name).font(.headline).lineLimit(1)
                        Image(systemName: "arrow.triangle.2.circlepath").font(.caption)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityLabel("Change store, \(store.name)")
                .accessibilityIdentifier("watch.store.switch")
                WatchSyncStatusButton(session: session)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .background(.background)
        }
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 44)
        .safeAreaInset(edge: .bottom, spacing: 4) {
            HStack(spacing: 6) {
                cartLink
                WatchCheckoutButton(session: session)
            }
            .buttonStyle(WatchCompactButtonStyle())
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .background(.background)
        }
        // Extend the inset to the screen edge; watchOS otherwise places it above
        // the curved-screen content safe area. The inset still reserves row space.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var cartLink: some View {
        NavigationLink { WatchCartView(session: session) } label: {
            Text("View cart").font(.caption2).frame(maxWidth: .infinity)
        }
        .accessibilityLabel("View cart, \(session.snapshot.cartCountText)")
        .accessibilityIdentifier("watch.cart.open")
    }

}

private struct WatchShoppingErrorPresenter: ViewModifier {
    let session: WatchShoppingSession
    let inSheet: Bool

    func body(content: Content) -> some View {
        content.alert("Couldn’t update Shopping", isPresented: Binding(
            get: { session.errorMessage != nil && (session.sheet != nil) == inSheet },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }
}

#if DEBUG
#Preview("Shopping") { WatchShoppingView(session: WatchShoppingSession(service: WatchPreviewService())) }
#Preview("Large text") {
    WatchShoppingView(session: WatchShoppingSession(service: WatchPreviewService(scenario: "longNames")))
        .environment(\.dynamicTypeSize, .accessibility3)
}
#Preview("Not set up") { WatchShoppingView(session: WatchShoppingSession(service: UnavailableWatchShoppingService())) }
#Preview("Empty") { WatchShoppingView(session: WatchShoppingSession(service: WatchPreviewService(scenario: "empty"))) }
#Preview("Loading") { ProgressView("Loading groceries") }
#Preview("Unavailable") { WatchShoppingView(session: WatchShoppingSession(service: WatchPreviewService(scenario: "unavailable"))) }
#endif
