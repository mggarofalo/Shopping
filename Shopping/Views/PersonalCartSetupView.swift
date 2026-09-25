import SwiftUI

struct PersonalCartSetupView: View {
    let activate: (Bool) -> Void
    @State private var confirmingImport = false

    var body: some View {
        List {
            Section {
                Text("Your cart belongs to you and follows your iPhone and Apple Watch. Household members can see cart presence, but can’t edit your cart.")
                Text("Set up with the iCloud account on this device. Existing cart entries need your review before becoming yours.")
            }
            Section {
                Button("Use existing iCloud groceries") { activate(false) }
                Button("Copy this device’s groceries to iCloud") { confirmingImport = true }
            } footer: {
                Text("Copy only from the first device. On your other devices, use the existing iCloud groceries. The original local data is retained.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Personal carts")
        .confirmationDialog("Copy these groceries to your iCloud account?", isPresented: $confirmingImport, titleVisibility: .visible) {
            Button("Copy groceries") { activate(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The grocery list, catalog and settings are copied. Old cart contents stay unattributed until you review and claim them.")
        }
    }
}

#Preview { NavigationStack { PersonalCartSetupView(activate: { _ in }) } }
