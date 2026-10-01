import SwiftUI

struct SettingsRecoveryView: View {
    let cart: PersonalCartPresentation

    var body: some View {
        List {
            if !cart.history.isEmpty || cart.error != nil {
                Section {
                    NavigationLink("My purchases") { PersonalPurchaseHistoryView(cart: cart) }
                } footer: {
                    Text("Review or undo purchases for this home.")
                }
            }
            Section {
                NavigationLink("Saved personal carts") { PersonalRetainedCartsView(service: cart.service) }
            } footer: {
                Text("Find saved carts and purchases, including homes you can no longer open.")
            }
            Section {
                NavigationLink("Review old cart entries") { LegacyCartReviewView(cart: cart) }
            } footer: {
                Text("Review cart entries saved before personal carts were set up, or restore earlier cleared groceries.")
            }
        }
        .navigationTitle("Recovery")
        .onAppear { cart.refresh() }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { SettingsRecoveryView(cart: cart) } } }
#endif
