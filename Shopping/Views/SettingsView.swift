import CoreData
import SwiftUI

struct SettingsView: View {
    @AppStorage("shopping.appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.homeScopeDisplay) private var homeScope

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HomeScopeControl()
                }
                Section(homeScope?.name ?? "Home settings") {
                    NavigationLink { StoreManagementView() } label: { Label("Stores", systemImage: "storefront") }
                    NavigationLink { CategoryManagementView() } label: { Label("Categories", systemImage: "square.grid.2x2") }
                    NavigationLink { PersonManagementView() } label: { Label("People", systemImage: "person.2") }
                }
                Section("Appearance") {
                    if dynamicTypeSize.isAccessibilitySize {
                        appearancePicker.pickerStyle(.menu)
                    } else {
                        appearancePicker.pickerStyle(.segmented)
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
            .navigationBarTitleDisplayMode(.inline)
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
