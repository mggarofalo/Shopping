import SwiftUI

struct CatalogItemRow: View {
    @ObservedObject var item: Item
    let grouping: CatalogGrouping
    let validStores: [Store]

    var body: some View {
        HStack(spacing: 10) {
            Text(item.name)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if !metadata.isEmpty {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(Color.grocerySecondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
            if item.isArchived {
                Image(systemName: "archivebox.fill")
                    .font(.caption)
                    .foregroundStyle(Color.grocerySecondary)
                    .accessibilityLabel("Archived")
            }
        }
    }

    private var metadata: String {
        var values: [String] = []
        if grouping != .category {
            values.append(item.category?.name ?? "Uncategorized")
        }
        if grouping != .store {
            values.append(storeSummary)
        }
        return values.joined(separator: " · ")
    }

    private var storeSummary: String {
        let assigned = item.stores ?? []
        let labels = validStores.filter { assigned.contains($0) }
            .map { $0.isArchived ? "\($0.name) (archived)" : $0.name }
        return CatalogSuggestionPurchaseSummary.text(
            anyStore: item.anyStore,
            savedStoreLabels: labels,
            hasSavedStores: !assigned.isEmpty
        )
    }
}

#Preview {
    ShoppingPreviewHost(.populated) {
        CatalogView(navigation: GroceryNavigationState())
    }
}
