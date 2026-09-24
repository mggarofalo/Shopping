import SwiftUI

struct WatchCartView: View {
    @ScaledMetric(relativeTo: .caption) private var bottomClearance = 60
    let session: WatchShoppingSession

    var body: some View {
        List {
            if session.snapshot.cartSections.isEmpty {
                Text("Your cart is empty").foregroundStyle(.secondary)
            }
            WatchItemSections(session: session, sections: session.snapshot.cartSections)
        }
        .listStyle(.plain)
        .contentMargins(.bottom, bottomClearance, for: .scrollContent)
        .navigationTitle("In cart")
        .toolbar(.visible, for: .navigationBar)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 44)
        // A real inset participates in scroll layout; the last row can clear the floating action.
        .safeAreaInset(edge: .bottom, spacing: 4) {
            WatchCheckoutButton(session: session)
                .buttonStyle(WatchCompactButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .padding(.bottom, 2)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { WatchCartView(session: WatchShoppingSession(service: WatchPreviewService())) }
}
#endif
