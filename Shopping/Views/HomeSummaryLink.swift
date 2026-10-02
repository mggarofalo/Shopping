import SwiftUI

struct HomeSummaryLink: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    let scope: ActiveHomeScope
    private var name: String { bootstrap.homeEntry.currentHomeName ?? "Home" }

    var body: some View {
        NavigationLink {
            HomeDetailsView(scope: scope, name: name, actions: bootstrap.homeDetailsActions(scope: scope))
        } label: {
            LabeledContent("Home") {
                Text(bootstrap.homeEntry.currentHomeDisplayName ?? name)
                    .accessibilityIdentifier("shopping.home.context")
            }
        }
        .accessibilityIdentifier("shopping.settings.homeDetails")
    }
}

#Preview { ShoppingPreviewHost(.populated) { SettingsView() } }
