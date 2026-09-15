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

struct GroceryScopeControls: View {
    @ObservedObject var navigation: GroceryNavigationState
    let stores: [Store]
    let categories: [Category]
    let showFilters: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                SelectionPill(
                    title: "All",
                    isSelected: navigation.selectedStoreID == nil,
                    identifier: "shopping.store.all"
                ) { navigation.selectAll() }
                storeMenu
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                filtersButton
            }
            activeFilterChips
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var activeFilterChips: some View {
        if navigation.activeFilterCount > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if navigation.urgentOnly {
                        filterChip("Urgent") { navigation.urgentOnly = false }
                    }
                    if let categoryID = navigation.categoryID,
                       let category = categories.first(where: { $0.id == categoryID }) {
                        filterChip(category.name) { navigation.categoryID = nil }
                    }
                    ForEach(stores.filter { navigation.includedStoreIDs.contains($0.id) }, id: \.objectID) { store in
                        filterChip("Includes \(store.name)") {
                            navigation.setIncluded(false, storeID: store.id)
                        }
                    }
                    ForEach(stores.filter { navigation.excludedStoreIDs.contains($0.id) }, id: \.objectID) { store in
                        filterChip("Excludes \(store.name)") {
                            navigation.setExcluded(false, storeID: store.id)
                        }
                    }
                }
            }
        }
    }

    private var storeMenu: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(stores, id: \.objectID) { store in
                    Button {
                        navigation.selectStore(store.id)
                    } label: {
                        if navigation.selectedStoreID == store.id {
                            Label(store.name, systemImage: "checkmark")
                        } else {
                            Text(store.name)
                        }
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "storefront").accessibilityHidden(true)
                    Text(selectedStoreName).fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .accessibilityLabel(selectedStoreName)
            .accessibilityHint("Choose a store")
            .accessibilityIdentifier("shopping.store.menu")
            if navigation.selectedStoreID != nil {
                Button { navigation.selectAll() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Clear selected store")
                .accessibilityIdentifier("shopping.store.clear")
            }
        }
    }

    private var filtersButton: some View {
        Button(action: showFilters) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").accessibilityHidden(true)
                Text(filterLabel).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(filterLabel)
        .accessibilityIdentifier("shopping.filters")
    }

    private var selectedStoreName: String {
        guard let id = navigation.selectedStoreID else { return "Choose store" }
        return stores.first(where: { $0.id == id })?.name ?? "Choose store"
    }

    private var filterLabel: String {
        navigation.activeFilterCount == 0 ? "Filters" : "Filters \(navigation.activeFilterCount)"
    }

    private func filterChip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            Label(title, systemImage: "xmark")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title) filter")
    }
}
