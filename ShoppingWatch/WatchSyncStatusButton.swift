import SwiftUI

struct WatchSyncStatusButton: View {
    let session: WatchShoppingSession

    var body: some View {
        NavigationLink { WatchSyncDetailsView(session: session) } label: {
            Image(systemName: session.snapshot.syncStatus.symbol)
                .font(.body)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sync status, \(session.snapshot.syncStatus.title)")
        .accessibilityHint("Show sync details")
        .accessibilityIdentifier("watch.sync.open")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        Text("Groceries")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                WatchSyncStatusButton(session: WatchShoppingSession(service: WatchPreviewService()))
            } }
    }
}
#endif
