import SwiftUI

struct HouseholdSettingsSection: View {
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.presentHomes) private var presentHomes
    @Environment(\.homeScopeDisplay) private var homeDisplay

    var body: some View {
        Section {
            if let scope = selection.homeScope {
                HomeSummaryLink(bootstrap: bootstrap, scope: scope)
            } else if bootstrap.homeEntry.root == .localHome || bootstrap.homeEntry.isShowingRetainedLocalHome {
                NavigationLink { LocalHomeSettingsView(bootstrap: bootstrap) } label: {
                    LabeledContent("Home") {
                        Text(homeDisplay?.name ?? "Home")
                            .accessibilityIdentifier("shopping.home.context")
                    }
                }
                .accessibilityIdentifier("shopping.settings.homeDetails")
            } else {
                Button("Homes", action: presentHomes)
                .accessibilityIdentifier("shopping.settings.homeDetails")
            }
        }
    }
}

#Preview { ShoppingPreviewHost(.populated) { NavigationStack { List { HouseholdSettingsSection() } } } }
