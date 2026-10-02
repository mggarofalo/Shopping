import SwiftUI

struct WatchHomeScopeLabel: View {
    let name: String?
    let identifier: String

    var body: some View {
        Label(name ?? "Saved Home", systemImage: "house")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Home, \(name ?? "Saved Home")")
            .accessibilityIdentifier(identifier)
    }
}

#Preview {
    List { WatchHomeScopeLabel(name: "Garofalo Home", identifier: "watch.home.preview") }
}
