import SwiftUI

struct LegacyCartReviewView: View {
    let cart: PersonalCartPresentation
    @State private var entries: [LegacyCartReviewSnapshot] = []
    @State private var error: String?

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
                    if entry.oldRecoveryPayload != nil {
                        Text("An older recovery record is retained. It cannot be automatically restored into a personal cart.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if entry.decision == "keep" {
                        if !entry.archived { Button("Claim as mine") { decide(entry, claim: true) } }
                        Button("Discard old cart status", role: .destructive) { decide(entry, claim: false) }
                    } else { Text(entry.decision == "claimed" ? "Claimed as mine" : "Old cart status discarded").foregroundStyle(.secondary) }
                }
            }
            if entries.isEmpty { Text("No old cart entries to review").foregroundStyle(.secondary) }
        }
        .navigationTitle("Old cart entries")
        .onAppear(perform: refresh)
        .alert("Couldn’t update entry", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func refresh() {
        do { entries = try cart.service.legacyReview().filter { $0.householdID == cart.householdID && $0.listID == cart.listID } }
        catch { self.error = error.localizedDescription }
    }

    private func decide(_ entry: LegacyCartReviewSnapshot, claim: Bool) {
        do { try cart.service.decideLegacyReview(id: entry.id, claim: claim); refresh(); cart.refresh() }
        catch { self.error = error.localizedDescription }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { LegacyCartReviewView(cart: cart) } } }
#endif
