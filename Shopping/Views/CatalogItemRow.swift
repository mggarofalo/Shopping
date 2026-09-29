import SwiftUI

struct CatalogItemRow: View {
    @ObservedObject var item: Item
    let validStores: [Store]

    var body: some View {
        ShoppingItemColumns {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.caption)
                        .foregroundStyle(Color.grocerySecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.isArchived {
                    Label("Archived", systemImage: "archivebox.fill")
                        .font(.caption).foregroundStyle(Color.grocerySecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            storeSummary
                .font(.caption)
                .foregroundStyle(Color.grocerySecondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .shoppingItemRow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.name, fullStoreSummary, item.notes, item.isArchived ? "Archived" : ""]
            .filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var storeSummary: some View {
        ShoppingItemStoreSummary(anyStore: item.anyStore, storeLabels: storeLabels,
            hasSavedStores: !(item.stores ?? []).isEmpty)
    }

    private var storeLabels: [String] {
        let assigned = item.stores ?? []
        return validStores.filter { assigned.contains($0) }
            .map { $0.isArchived ? "\($0.name) (archived)" : $0.name }.sorted()
    }

    private var fullStoreSummary: String {
        CatalogSuggestionPurchaseSummary.text(anyStore: item.anyStore, savedStoreLabels: storeLabels,
            hasSavedStores: !(item.stores ?? []).isEmpty)
    }
}

#Preview {
    ShoppingPreviewHost(.populated) {
        CatalogView(navigation: GroceryNavigationState())
    }
}
