import SwiftUI

struct HomeSummaryLink: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @ObservedObject var coordinator: ActiveHomeCoordinator
    let scope: ActiveHomeScope
    private var name: String { coordinator.homes.first(where: { $0.graph == scope.graph })?.name ?? "Current home" }

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
