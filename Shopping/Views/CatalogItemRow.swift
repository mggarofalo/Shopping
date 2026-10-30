import SwiftUI

/// Everything a Catalog row displays, read from Core Data by its screen. Rows compare these
/// values, so a screen update that leaves a row's data unchanged skips that row (SHOPPING-272).
struct CatalogRowModel: Equatable {
    let itemID: UUID
    let name: String
    let notes: String
    let isArchived: Bool
    let anyStore: Bool
    let storeLabels: [String]
    let hasSavedStores: Bool

    init(item: Item, validStores: [Store]) {
        let assigned = item.stores ?? []
        itemID = item.id
        name = item.name
        notes = item.notes
        isArchived = item.isArchived
        anyStore = item.anyStore
        storeLabels = validStores.filter { assigned.contains($0) }
            .map { $0.isArchived ? "\($0.name) (archived)" : $0.name }.sorted()
        hasSavedStores = !assigned.isEmpty
    }

    var storeSummary: String {
        CatalogSuggestionPurchaseSummary.text(anyStore: anyStore, savedStoreLabels: storeLabels,
            hasSavedStores: hasSavedStores)
    }
}

struct CatalogItemRow: View, Equatable {
    let model: CatalogRowModel

#if DEBUG
    /// Records each body evaluation, so tests can prove unchanged rows are skipped.
    @MainActor static var renderedItemIDs: [UUID] = []
#endif

    var body: some View {
#if DEBUG
        let _ = Self.renderedItemIDs.append(model.itemID)
#endif
        return ShoppingItemRowContent(storeSummary: ShoppingItemStoreSummary(anyStore: model.anyStore,
            storeLabels: model.storeLabels, hasSavedStores: model.hasSavedStores)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.notes.isEmpty {
                    Text(model.notes)
                        .font(.caption)
                        .foregroundStyle(Color.grocerySecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isArchived {
                    Label("Archived", systemImage: "archivebox.fill")
                        .font(.caption).foregroundStyle(Color.grocerySecondary)
                }
            }
        }
        .shoppingItemRow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([model.name, model.storeSummary, model.notes, model.isArchived ? "Archived" : ""]
            .filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

#Preview {
    ShoppingPreviewHost(.populated) {
        CatalogView(navigation: GroceryNavigationState())
    }
}
