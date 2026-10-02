import SwiftUI

struct HouseholdSettingsSection: View {
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.presentHomes) private var presentHomes

    var body: some View {
        Section {
            if let scope = selection.homeScope {
                HomeSummaryLink(bootstrap: bootstrap, scope: scope)
            } else if bootstrap.homeEntry.root == .localHome || bootstrap.homeEntry.isShowingRetainedLocalHome {
                NavigationLink("Home") { LocalHomeSettingsView(bootstrap: bootstrap) }
                .accessibilityIdentifier("shopping.settings.homeDetails")
            } else {
                Button("Homes", action: presentHomes)
                .accessibilityIdentifier("shopping.settings.homeDetails")
            }
        }
    }
}

#Preview { ShoppingPreviewHost(.populated) { NavigationStack { List { HouseholdSettingsSection() } } } }
