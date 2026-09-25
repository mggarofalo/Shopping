import SwiftUI

struct WatchRecoveryView: View {
    let session: WatchShoppingSession
    @State private var confirming: WatchRecoveryOperation?

    var body: some View {
        List {
            if session.snapshot.recentCheckouts.isEmpty { Text("Nothing to recover") }
            ForEach(session.snapshot.recentCheckouts) { operation in
                Section(operation.storeName) {
                    Text(operation.summary).font(.footnote)
                    Button("Restore items") { confirming = operation }
                        .disabled(!operation.canRestore || session.isBusy)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Recently cleared")
        .confirmationDialog("Restore your cleared items?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), titleVisibility: .visible) {
            if let operation = confirming {
                Button("Restore items") {
                    Task { await session.restore(operation) }
                    confirming = nil
                }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { Text("Newer changes will be kept. Other shoppers’ carts are unchanged.") }
    }
}

#if DEBUG
#Preview { NavigationStack { WatchRecoveryView(session: WatchPreviewService.previewSession()) } }
#endif
