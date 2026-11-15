import CoreData
import SwiftUI

struct CatalogFilterState: Equatable {
    var selectedStoreID: UUID?
    var includedStoreIDs: Set<UUID> = []
    var excludedStoreIDs: Set<UUID> = []
    var categoryIDs: Set<UUID> = []
    var showArchived = false

    var count: Int {
        includedStoreIDs.count + excludedStoreIDs.count + categoryIDs.count + (showArchived ? 1 : 0)
    }

    func query(text: String) -> CatalogItemFilter {
        CatalogItemFilter(purchase: PurchaseFilter(
            selectedStoreID: selectedStoreID,
            includedStoreIDs: includedStoreIDs,
            excludedStoreIDs: excludedStoreIDs
        ), text: text, categoryIDs: categoryIDs)
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

/// The list and catalog items one membership read covered.
struct CatalogMembershipRead: Equatable {
    let householdID: UUID
    let listID: UUID
    let itemIDs: Set<UUID>
}

/// Captures one displayed grocery occurrence so a stale swipe cannot remove a replacement.
struct CatalogNeedRemovalTarget: Equatable {
    let needID: UUID
    let revision: Int64
    let householdID: UUID
    let listID: UUID
}

/// Whether a catalog item already has a current need. Add to Groceries results and the item
/// editor's suggestions share this wording so the two lists describe an item the same way.
enum CatalogNeedStatus: Equatable {
    case notNeeded
    case onList
    case inCart

    @MainActor
    init(activeNeed: Need?, personalCart: PersonalCartPresentation?) {
        guard let activeNeed else {
            self = .notNeeded
            return
        }
        self = (personalCart?.contains(activeNeed.id) ?? activeNeed.carted) ? .inCart : .onList
    }

    /// Searching the catalog already implies an item is saved there, so only a current need
    /// has a label.
    var label: String? {
        switch self {
        case .notNeeded: nil
        case .onList: "On grocery list"
        case .inCart: "In cart"
        }
    }

    /// The row's spoken value: the item's saved details, then its need state. Store summaries
    /// already use commas, so a middle dot keeps the state from sounding like another store.
    func accessibilityValue(details: String) -> String {
        [details, label].compactMap { $0 }.joined(separator: " · ")
    }
}
