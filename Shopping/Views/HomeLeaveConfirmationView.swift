import SwiftUI

struct HomeLeaveConfirmationView: View {
    let homeName: String
    let canConfirm: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Text(homeName).font(.headline)
                Text("Leaving removes this home’s shared working copy from this device. Changes that have not finished syncing may not reach the home.")
                Text("Your personal cart and purchase history stay saved. Unsent checkout and undo changes won’t be sent automatically if you join again.")
                Button("Leave now", role: .destructive, action: onConfirm)
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("shopping.home.confirmLeave")
            }
            .navigationTitle("Leave home?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("shopping.home.cancelLeave")
                }
            }
        }
    }
}

#Preview {
    HomeLeaveConfirmationView(homeName: "Our home", canConfirm: true,
        onConfirm: {}, onCancel: {})
}
