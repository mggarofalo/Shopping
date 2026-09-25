import SwiftUI

struct LegacyCartReviewView: View {
    let cart: PersonalCartPresentation
    @State private var entries: [LegacyCartReviewSnapshot] = []
    @State private var error: String?
    @State private var resultMessage: String?

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
                    Button("Discard old cart status", role: .destructive) { decide(entry, claim: false) }
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
        .onAppear(perform: refresh)
        .alert("Couldn’t update entry", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func refresh() {
        do { entries = try cart.service.pendingLegacyReview(householdID: cart.householdID, listID: cart.listID) }
        catch { self.error = error.localizedDescription }
    }

    private func decide(_ entry: LegacyCartReviewSnapshot, claim: Bool) {
        do {
            try cart.service.decideLegacyReview(id: entry.id, claim: claim)
            resultMessage = claim ? "Claimed as mine" : "Old cart status discarded"
            refresh()
            cart.refresh()
        }
        catch { self.error = error.localizedDescription }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { LegacyCartReviewView(cart: cart) } } }
#endif
