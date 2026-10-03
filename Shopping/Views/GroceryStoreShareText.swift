import CoreData
import Foundation

/// A store-wide list, deliberately independent of search and advanced view filters.
/// Callers supply the same outstanding, uncarted occurrences used by Groceries.
enum GroceryStoreShareText {
    static func text(
        outstandingNeeds: [Need],
        selectedStoreID: UUID?,
        activeStores: [Store],
        categories: [Category],
        household: Household?
    ) -> String {
        guard let selectedStoreID,
              activeStores.contains(where: { $0.id == selectedStoreID && !$0.isArchived }) else { return "" }
        let sections = GroceryCollectionProjection.sections(
            needs: outstandingNeeds,
            selectedStoreID: selectedStoreID,
            activeStores: activeStores,
            categories: categories,
            household: household
        )
        return lines(names: sections.flatMap(\.items).map { $0.item?.name ?? $0.title })
    }

    /// Embedded line breaks must not turn one grocery into several shared items.
    static func lines(names: [String]) -> String {
        names.map { name in
            name.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}
