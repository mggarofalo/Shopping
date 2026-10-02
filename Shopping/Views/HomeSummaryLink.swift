import SwiftUI

struct HomeSummaryLink: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    let scope: ActiveHomeScope
    private var name: String { bootstrap.homeEntry.currentHomeName ?? "Home" }

    var body: some View {
        NavigationLink {
            HomeDetailsView(scope: scope, name: name, actions: bootstrap.homeDetailsActions(scope: scope))
        } label: {
            LabeledContent("Home", value: name)
        }
        .accessibilityIdentifier("shopping.settings.homeDetails")
    }
}

#Preview { ShoppingPreviewHost(.populated) { SettingsView() } }
