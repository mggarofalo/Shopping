import SwiftUI

/// The shared Catalog and Grocery item layout: the description leads, and the store summary
/// trails in the narrower column. At accessibility sizes the description gets the full width
/// and the right-aligned store summary follows it, so names wrap between words.
/// Its text padding sits inside the caller's 44-point minimum (`shoppingItemRow()` or a tap
/// target), so single-line rows keep the standard height.
struct ShoppingItemRowContent<Description: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let storeSummary: ShoppingItemStoreSummary
    @ViewBuilder let description: Description

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    leadingDescription
                    storeSummary
                }
            } else {
                ShoppingItemColumns {
                    leadingDescription
                    storeSummary
                }
            }
        }
        .padding(.vertical, ShoppingListMetrics.itemTextVerticalPadding)
    }

    private var leadingDescription: some View {
        description.frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    List {
        ShoppingItemRowContent(storeSummary: ShoppingItemStoreSummary(
            anyStore: false, storeLabels: ["Costco", "Publix"], hasSavedStores: true)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Granola")
                Text("Low sugar").font(.caption).foregroundStyle(Color.grocerySecondary)
            }
        }
        .shoppingItemRow()
    }
}
