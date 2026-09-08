import SwiftUI

struct PersistenceRecoveryView: View {
    let error: Error
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Groceries unavailable")
                    .font(.title2.bold())
                    .shoppingMultilineText()
                Text("Your saved data was left unchanged. Try opening it again.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .shoppingMultilineText()
                    .accessibilityIdentifier("shopping.persistence.description")
                DisclosureGroup {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .shoppingMultilineText()
                        .textSelection(.enabled)
                } label: {
                    Text("Technical details")
                        .shoppingMultilineText()
                }
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shopping.persistence.retry")
            }
            .padding()
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    PersistenceRecoveryView(error: CocoaError(.fileReadUnknown), retry: {})
}
