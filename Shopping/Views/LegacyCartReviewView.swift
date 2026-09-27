import SwiftUI

struct LegacyCartReviewView: View {
    let cart: PersonalCartPresentation
    @State private var entries: [LegacyCartReviewSnapshot] = []
    @State private var error: String?
    @State private var resultMessage: String?
    @State private var pendingDecisionIDs: Set<UUID> = []

    var body: some View {
        List {
            Section {
                Text("These old cart entries have no known owner. Claim only your own entries, discard the old cart status, or leave them here for later. The grocery request and catalog are retained.")
            }
            ForEach(entries) { entry in
                Section {
                    Text(entry.title)
                    if let quantity = entry.quantity { Text("Quantity: \(quantity)") }
                    if entry.oneTime { Text("One-time item").foregroundStyle(.secondary) }
                    Button("Claim as mine") { decide(entry, claim: true) }
                        .disabled(pendingDecisionIDs.contains(entry.id))
                    Button("Discard old cart status", role: .destructive) { decide(entry, claim: false) }
                        .disabled(pendingDecisionIDs.contains(entry.id))
                }
            }
            if entries.isEmpty { Text("No old cart entries to review").foregroundStyle(.secondary) }
            if let resultMessage { Text(resultMessage).foregroundStyle(.secondary) }
            Section("Earlier history") {
                Text("Earlier cleared groceries are kept separately from your personal purchases. Restoring them returns unchanged requests to the household list without claiming a cart.")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("Earlier cleared groceries") { RecentlyClearedView() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Old cart entries")
        .task { await refresh() }
        .alert("Couldn’t update entry", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func refresh() async {
        let service = cart.service
        let householdID = cart.householdID
        let listID = cart.listID
        do { entries = try await Task.detached(priority: .userInitiated) {
            try service.pendingLegacyReview(householdID: householdID, listID: listID)
        }.value }
        catch { self.error = error.localizedDescription }
    }

    private func decide(_ entry: LegacyCartReviewSnapshot, claim: Bool) {
        guard pendingDecisionIDs.insert(entry.id).inserted else { return }
        let service = cart.service
        Task {
            defer { pendingDecisionIDs.remove(entry.id) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.decideLegacyReview(id: entry.id, claim: claim)
                }.value
                resultMessage = claim ? "Claimed as mine" : "Old cart status discarded"
                await refresh()
                cart.refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { LegacyCartReviewView(cart: cart) } } }
#endif
