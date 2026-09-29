import CoreData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.sharingStatusPresentation) private var sharingStatus
    @AppStorage("shopping.appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.personalCart) private var personalCart
    @Environment(\.activatePersonalCart) private var activatePersonalCart

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { StoreManagementView() } label: { Label("Stores", systemImage: "storefront") }
                    .shoppingListRowInsets()
                NavigationLink { CategoryManagementView() } label: { Label("Categories", systemImage: "square.grid.2x2") }
                    .shoppingListRowInsets()
                NavigationLink { PersonManagementView() } label: { Label("People", systemImage: "person.2") }
                    .shoppingListRowInsets()
                Section("Appearance") {
                    if dynamicTypeSize.isAccessibilitySize {
                        appearancePicker.pickerStyle(.menu).shoppingListRowInsets()
                    } else {
                        appearancePicker.pickerStyle(.segmented).shoppingListRowInsets()
                    }
                }
                Section("Household") {
                    if let scope = selection.homeScope {
                        HomeSummaryLink(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator,
                            scope: scope, status: sharingStatus.title)
                    }
                    if selection.homeScope != nil || bootstrap.isShowingRetainedLocalHome || bootstrap.retainedLocalHomeName != nil {
                        NavigationLink("Homes") {
                            HomeSelectionView(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator)
                        }
                    }
                    NavigationLink {
                        List {
                            Section("Status") {
                                Label(sharingStatus.title, systemImage: sharingStatus.symbol)
                                Text(sharingStatus.details)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .navigationTitle("Sync status")
                    } label: {
                        LabeledContent("Sync status") {
                            Image(systemName: sharingStatus.symbol)
                                .accessibilityLabel(sharingStatus.title)
                        }
                    }
                    .accessibilityIdentifier("shopping.settings.sharingStatus")
                    if let personalCart {
                        NavigationLink("My purchases") { PersonalPurchaseHistoryView(cart: personalCart) }
                        NavigationLink("Saved personal carts") { PersonalRetainedCartsView(service: personalCart.service) }
                        NavigationLink("Review old cart entries") { LegacyCartReviewView(cart: personalCart) }
                    } else if let activatePersonalCart {
                        NavigationLink("Set up personal carts") {
                            PersonalCartSetupView(activate: activatePersonalCart)
                        }
                    }
                }
                Section("About") {
                    LabeledContent("App Version") {
                        Text(AppVersion.current.displayValue)
                            .accessibilityIdentifier("shopping.settings.version")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
    }
    private var appearancePicker: some View {
        Picker("Color scheme", selection: $appearance) {
            ForEach(AppearancePreference.allCases) { preference in
                Text(preference.title).tag(preference.rawValue)
            }
        }
        .accessibilityIdentifier("shopping.appearance")
    }

}

private struct HomeSummaryLink: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @ObservedObject var coordinator: ActiveHomeCoordinator
    let scope: ActiveHomeScope
    let status: String
    private var name: String { coordinator.homes.first(where: { $0.graph == scope.graph })?.name ?? "Current home" }

    var body: some View {
        NavigationLink {
            HomeDetailsView(scope: scope, name: name, actions: bootstrap.homeDetailsActions(scope: scope))
        } label: {
            VStack(alignment: .leading) {
                Text(name)
                Text("Home details · \(status)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("shopping.settings.homeDetails")
    }
}

#Preview("Store settings · archived") { ShoppingPreviewHost(.archivedStore) { SettingsView() } }
#Preview("Store settings · empty") { ShoppingPreviewHost(.empty) { SettingsView() } }
#Preview("Store management · archived") {
    ShoppingPreviewHost(.archivedStore) { NavigationStack { StoreManagementView() } }
}
