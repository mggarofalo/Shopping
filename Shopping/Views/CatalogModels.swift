import CoreData
import SwiftUI

struct CatalogFilterState: Equatable {
    var includedStoreIDs: Set<UUID> = []
    var excludedStoreIDs: Set<UUID> = []
    var categoryIDs: Set<UUID> = []
    var showArchived = false

    var count: Int {
        includedStoreIDs.count + excludedStoreIDs.count + categoryIDs.count + (showArchived ? 1 : 0)
    }

    func query(text: String) -> CatalogItemFilter {
        CatalogItemFilter(purchase: PurchaseFilter(
            includedStoreIDs: includedStoreIDs,
            excludedStoreIDs: excludedStoreIDs
        ), text: text, categoryIDs: categoryIDs)
    }
}

enum CatalogGrouping: String, CaseIterable, Identifiable {
    case category
    case store
    case none

    var id: Self { self }
    var title: String {
        switch self {
        case .category: "Category"
        case .store: "Store"
        case .none: "None"
        }
    }
}


enum CatalogScope {
    static func canonicalList(
        lists: [GroceryList],
        households: [Household],
        selection: PersistenceSelection
    ) -> GroceryList? {
        GroceryRowScope.canonicalList(lists, households: households, selection: selection)
    }

    static func items(_ items: [Item], household: Household?) -> [Item] {
        guard let household else { return [] }
        let counts = Dictionary(grouping: items, by: \.id).mapValues(\.count)
        return items.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 && $0.household == household &&
                $0.objectID.persistentStore == household.objectID.persistentStore
        }
    }

    static func categories(_ categories: [Category], household: Household?) -> [Category] {
        guard let household else { return [] }
        let counts = Dictionary(grouping: categories, by: \.id).mapValues(\.count)
        return categories.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 && $0.household == household &&
                $0.objectID.persistentStore == household.objectID.persistentStore
        }
    }
}

struct CatalogEditSession: Identifiable {
    let id = UUID()
    let selection: PersistenceSelection
    let itemID: UUID?
    let values: CatalogItemValues
}

struct CatalogArchiveTarget {
    let itemID: UUID
    let householdID: UUID
    let listID: UUID
    let archived: Bool
}

struct CatalogRemovalTarget {
    let itemID: UUID
    let householdID: UUID
    let listID: UUID
    let name: String
    let preview: CatalogRemovalPreview
}

struct CatalogAddConfirmation: Identifiable {
    let id = UUID()
    let preview: CatalogAddPreview
    let itemName: String?
}

struct CatalogRefreshKey: Equatable {
    let id: UUID
    let revision: Int64
    let archived: Bool
}
