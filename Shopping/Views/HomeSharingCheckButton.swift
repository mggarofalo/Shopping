import SwiftUI

struct HomeSharingCheckButton: View {
    let isChecking: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var symbolWidth = 28

    var body: some View {
        Button(action: action) {
            HStack {
                Text("Check status")
                Spacer()
                Image(systemName: isChecking ? "arrow.triangle.2.circlepath.icloud" : "icloud")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isChecking ? Color.accentColor : Color.secondary)
                    .symbolEffect(.pulse, isActive: isChecking && !reduceMotion)
                    .frame(width: symbolWidth)
                    .accessibilityHidden(true)
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

