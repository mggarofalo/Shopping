import CoreData
import SwiftUI
import UIKit

struct GroceryFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var navigation: GroceryNavigationState
    let stores: [Store]
    let categories: [Category]
    let onReset: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Urgent only", isOn: $navigation.urgentOnly)
                Section("Category") {
                    PillFlowLayout {
                        SelectionPill(title: "Any category", isSelected: navigation.categoryID == nil) {
                            navigation.categoryID = nil
                        }
                        ForEach(categories, id: \.objectID) { category in
                            SelectionPill(title: category.name, isSelected: navigation.categoryID == category.id) {
                                navigation.categoryID = navigation.categoryID == category.id ? nil : category.id
                            }
                        }
                    }
                }
                Section("Include stores") {
                    PillFlowLayout {
                        ForEach(stores, id: \.objectID) { store in
                            SelectionPill(
                                title: store.name,
                                isSelected: navigation.includedStoreIDs.contains(store.id),
                                identifier: "shopping.filters.include.\(store.id.uuidString)"
                            ) { navigation.setIncluded(!navigation.includedStoreIDs.contains(store.id), storeID: store.id) }
                        }
                    }
                }
                Section("Exclude stores") {
                    PillFlowLayout {
                        ForEach(stores, id: \.objectID) { store in
                            SelectionPill(
                                title: store.name,
                                isSelected: navigation.excludedStoreIDs.contains(store.id),
                                identifier: "shopping.filters.exclude.\(store.id.uuidString)"
                            ) { navigation.setExcluded(!navigation.excludedStoreIDs.contains(store.id), storeID: store.id) }
                        }
                    }
                }
                Button("Reset filters", action: onReset)
            }
            .navigationTitle("Filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
