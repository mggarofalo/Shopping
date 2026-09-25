import SwiftUI

struct WatchSyncDetailsView: View {
    let session: WatchShoppingSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Label(session.snapshot.syncStatus.title, systemImage: session.snapshot.syncStatus.symbol)
                .font(.headline)
            Text(session.snapshot.syncStatus.details)
                .font(.footnote)
                .accessibilityIdentifier("watch.sync.details")
            Button("Done") { dismiss() }
                .accessibilityIdentifier("watch.sync.done")
        }
        .listStyle(.plain)
        .navigationTitle("Sync")
        .toolbar(.visible, for: .navigationBar)
    }
}

#if DEBUG
#Preview {
    NavigationStack { WatchSyncDetailsView(session: WatchShoppingSession(service: WatchPreviewService())) }
}
#endif
