import CoreData
import SwiftUI

struct SettingsView: View {
    @AppStorage("shopping.appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { StoreManagementView() } label: { Label("Stores", systemImage: "storefront") }
                    .shoppingListRowInsets()
                NavigationLink { CategoryManagementView() } label: { Label("Categories", systemImage: "square.grid.2x2") }
                    .shoppingListRowInsets()
                Section("Appearance") {
                    if dynamicTypeSize.isAccessibilitySize {
                        appearancePicker.pickerStyle(.menu).shoppingListRowInsets()
                    } else {
                        appearancePicker.pickerStyle(.segmented).shoppingListRowInsets()
                    }
                }
                Section("Household") {
                    LabeledContent("Sharing status", value: "Not connected")
                        .shoppingListRowInsets()
                    Text("Groceries are available in this app’s current local household store.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .shoppingMultilineText()
                        .accessibilityIdentifier("shopping.settings.householdDescription")
                        .shoppingListRowInsets()
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
