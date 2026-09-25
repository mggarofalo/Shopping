import SwiftUI

struct WatchCartView: View {
    let session: WatchShoppingSession

    var body: some View {
        List {
            if session.snapshot.cartSections.isEmpty {
                Text("Your cart is empty").foregroundStyle(.secondary)
            }
            WatchItemSections(session: session, sections: session.snapshot.cartSections)
        }
        .listStyle(.plain)
        .navigationTitle("In cart")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { WatchSyncStatusButton(session: session) } }
        .toolbar(.visible, for: .navigationBar)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 44)
        .safeAreaInset(edge: .bottom, spacing: 4) {
            HStack {
                WatchCheckoutButton(session: session)
                    .buttonStyle(WatchCompactButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
            .background(.background)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

#if DEBUG
#Preview {
    NavigationStack { WatchCartView(session: WatchShoppingSession(service: WatchPreviewService())) }
}
#endif
