import SwiftUI

struct HouseholdSettingsSection: View {
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.sharingStatusPresentation) private var sharingStatus
    @Environment(\.personalCart) private var personalCart
    @Environment(\.activatePersonalCart) private var activatePersonalCart

    var body: some View {
        Section("Household") {
            if let scope = selection.homeScope {
                HomeSummaryLink(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator,
                    scope: scope)
            }
            if selection.homeScope != nil || bootstrap.isShowingRetainedLocalHome || bootstrap.retainedLocalHomeName != nil {
                NavigationLink("Homes") {
                    HomeSelectionView(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator)
                }
            }
            NavigationLink {
                HomeSharingStatusView()
            } label: {
                LabeledContent("Sharing status") {
                    Image(systemName: sharingStatus.symbol)
                        .accessibilityLabel(sharingStatus.title)
                }
            }
            .accessibilityIdentifier("shopping.settings.sharingStatus")
            if let personalCart {
                NavigationLink("Recovery") { SettingsRecoveryView(cart: personalCart) }
                    .accessibilityIdentifier("shopping.settings.recovery")
            } else if let activatePersonalCart {
                NavigationLink("Set up personal carts") {
                    PersonalCartSetupView(activate: activatePersonalCart)
                }
            }
        }
    }
}

#Preview { ShoppingPreviewHost(.populated) { NavigationStack { List { HouseholdSettingsSection() } } } }
