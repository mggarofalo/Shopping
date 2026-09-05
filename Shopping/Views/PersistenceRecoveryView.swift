import SwiftUI

struct PersistenceRecoveryView: View {
    let error: Error
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Groceries unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Your saved data was left unchanged. Try opening it again.")
        } actions: {
            VStack(spacing: 12) {
                DisclosureGroup("Technical details") {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shopping.persistence.retry")
            }
        }
        .accessibilityIdentifier("shopping.persistence.error")
    }
}

#Preview {
    PersistenceRecoveryView(error: CocoaError(.fileReadUnknown), retry: {})
}
