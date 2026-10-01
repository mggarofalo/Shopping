import SwiftUI

struct HomeSharingCheckButton: View {
    let isChecking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("Check status")
                Spacer()
                HomeCloudSymbol(isWorking: isChecking)
            }
        }
        .disabled(isChecking)
        .accessibilityLabel("Check status")
        .accessibilityValue(isChecking ? "Checking" : "")
        .accessibilityIdentifier("shopping.sharing.check")
    }
}

#Preview("Check activity") {
    NavigationStack {
        List {
            Section("Ready") { HomeSharingCheckButton(isChecking: false) {} }
            Section("Checking") { HomeSharingCheckButton(isChecking: true) {} }
        }
        .navigationTitle("Sharing status")
    }
}

