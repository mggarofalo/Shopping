import SwiftUI

struct CatalogItemRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var item: Item
    let validStores: [Store]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize {
                titleAndMetadataStack
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        title
                        Spacer(minLength: 8)
                        supportingMetadata
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    titleAndMetadataStack
                }
            }
            if !item.notes.isEmpty {
                Text(item.notes)
                    .font(.caption)
                    .foregroundStyle(Color.grocerySecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var title: some View {
        Text(item.name).foregroundStyle(.primary)
    }

    private var titleAndMetadataStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            supportingMetadata
        }
    }

    private var supportingMetadata: some View {
        HStack(spacing: 6) {
            if !metadata.isEmpty {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(Color.grocerySecondary)
            }
            if item.isArchived {
                Image(systemName: "archivebox.fill")
                    .font(.caption)
                    .foregroundStyle(Color.grocerySecondary)
                    .accessibilityLabel("Archived")
            }
        }
    }

    private var accessibilityLabel: String {
        [item.name, metadata, item.notes].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var metadata: String {
        storeSummary
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
