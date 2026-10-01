import SwiftUI

struct HouseholdSettingsSection: View {
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.personalCart) private var personalCart
    @Environment(\.activatePersonalCart) private var activatePersonalCart

    var body: some View {
        Section {
            if let scope = selection.homeScope {
                HomeSummaryLink(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator, scope: scope)
            } else if personalCart == nil, let activatePersonalCart, !bootstrap.isShowingRetainedLocalHome,
                      bootstrap.retainedLocalHomeName == nil {
                NavigationLink("Home") {
                    PersonalCartSetupView(activate: activatePersonalCart)
                }
                .accessibilityIdentifier("shopping.settings.homeDetails")
            } else {
                NavigationLink("Home") {
                    HomeSelectionView(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator)
                }
                .accessibilityIdentifier("shopping.settings.homeDetails")
            }
        }
    }
}

#Preview { ShoppingPreviewHost(.populated) { NavigationStack { List { HouseholdSettingsSection() } } } }
