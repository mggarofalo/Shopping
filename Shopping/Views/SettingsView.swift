import CoreData
import SwiftUI

struct SettingsView: View {
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
                    LabeledContent("Sharing Status") {
                        Text("Not Connected")
                            .accessibilityIdentifier("shopping.settings.sharingStatus")
                    }
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

#Preview("Store settings · archived") { ShoppingPreviewHost(.archivedStore) { SettingsView() } }
#Preview("Store settings · empty") { ShoppingPreviewHost(.empty) { SettingsView() } }
#Preview("Store management · archived") {
    ShoppingPreviewHost(.archivedStore) { NavigationStack { StoreManagementView() } }
}
