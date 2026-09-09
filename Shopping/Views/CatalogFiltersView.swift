import SwiftUI

struct CatalogFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: CatalogFilterState
    let stores: [Store]
    let categories: [Category]

    var body: some View {
        NavigationStack {
            Form {
                Section("Include stores") {
                    PillFlowLayout {
                        ForEach(stores, id: \.objectID) { store in
                            SelectionPill(
                                title: store.name,
                                isSelected: filters.includedStoreIDs.contains(store.id),
                                identifier: "shopping.catalog.filters.include.\(store.id.uuidString)"
                            ) { toggle(store.id, in: $filters.includedStoreIDs) }
                        }
                    }
                }
                Section("Exclude stores") {
                    PillFlowLayout {
                        ForEach(stores, id: \.objectID) { store in
                            SelectionPill(
                                title: store.name,
                                isSelected: filters.excludedStoreIDs.contains(store.id),
                                identifier: "shopping.catalog.filters.exclude.\(store.id.uuidString)"
                            ) { toggle(store.id, in: $filters.excludedStoreIDs) }
                        }
                    }
                }
                Section("Categories") {
                    PillFlowLayout {
                        ForEach(categories, id: \.objectID) { category in
                            SelectionPill(
                                title: category.name,
                                isSelected: filters.categoryIDs.contains(category.id)
                            ) { toggle(category.id, in: $filters.categoryIDs) }
                        }
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        Button {
                            filters.showArchived.toggle()
                        } label: {
                            Label("Archived", systemImage: filters.showArchived ? "archivebox.fill" : "archivebox")
                        }
                        .accessibilityIdentifier("shopping.catalog.archived")
                        Spacer()
                        Button("Reset", systemImage: "arrow.counterclockwise") {
                            filters = CatalogFilterState()
                        }
                        .disabled(filters.count == 0)
                        .accessibilityIdentifier("shopping.catalog.reset")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .navigationTitle("Catalog filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func toggle(_ id: UUID, in ids: Binding<Set<UUID>>) {
        if ids.wrappedValue.contains(id) { ids.wrappedValue.remove(id) }
        else { ids.wrappedValue.insert(id) }
    }
}
