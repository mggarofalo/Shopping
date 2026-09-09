import CoreData
import SwiftUI
import UIKit

enum NavigationFetchRequests {
    static func stores() -> NSFetchRequest<Store> {
        let request = configured(Store.fetchRequest(), sortKey: "displayOrder")
        request.sortDescriptors?.append(NSSortDescriptor(key: "id", ascending: true))
        return request
    }

    static func needs() -> NSFetchRequest<Need> {
        configured(Need.fetchRequest(), sortKey: "title")
    }

    static func clearOperations() -> NSFetchRequest<ClearOperation> {
        configured(ClearOperation.fetchRequest(), sortKey: "createdAt", ascending: false)
    }

    static func items() -> NSFetchRequest<Item> {
        configured(Item.fetchRequest(), sortKey: "name")
    }

    static func categories() -> NSFetchRequest<Category> {
        let request = configured(Category.fetchRequest(), sortKey: "displayOrder")
        request.sortDescriptors?.append(NSSortDescriptor(key: "id", ascending: true))
        return request
    }

    static func lists() -> NSFetchRequest<GroceryList> {
        configured(GroceryList.fetchRequest(), sortKey: "id")
    }

    static func households() -> NSFetchRequest<Household> {
        configured(Household.fetchRequest(), sortKey: "id")
    }

    private static func configured<Result: NSFetchRequestResult>(
        _ request: NSFetchRequest<Result>,
        sortKey: String,
        ascending: Bool = true
    ) -> NSFetchRequest<Result> {
        request.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
        return request
    }
}

struct PendingSavedNeed {
    let id: UUID
    let scope: GroceryAddScope
    let expectsUncarted: Bool
    let originalCategoryID: UUID?
    let savedCategoryID: UUID?
    let wasEditing: Bool
}

enum GroceryRowScope {
    static func canonicalList(
        _ lists: [GroceryList],
        households: [Household],
        selection: PersistenceSelection
    ) -> GroceryList? {
        guard let householdID = selection.householdID, let listID = selection.listID,
              householdID != PersistenceModel.unsetID, listID != PersistenceModel.unsetID else { return nil }
        let matches = lists.filter { $0.id == listID }
        let matchingHouseholds = households.filter { $0.id == householdID }
        guard matches.count == 1, matchingHouseholds.count == 1,
              matches[0].household == matchingHouseholds[0],
              let household = matches[0].household,
              let store = household.objectID.persistentStore,
              matches[0].objectID.persistentStore == store else { return nil }
        return matches[0]
    }

    static func validStores(_ stores: [Store], canonicalList: GroceryList?) -> [Store] {
        guard let household = canonicalList?.household,
              let persistentStore = household.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: stores, by: \.id).mapValues(\.count)
        return stores.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }

    static func validCategories(_ categories: [Category], canonicalList: GroceryList?) -> [Category] {
        guard let household = canonicalList?.household,
              let persistentStore = household.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: categories, by: \.id).mapValues(\.count)
        return categories.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }

    static func validItems(_ items: [Item], canonicalList: GroceryList?) -> [Item] {
        guard let household = canonicalList?.household,
              let persistentStore = household.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: items, by: \.id).mapValues(\.count)
        return items.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }

    static func validNeeds(_ needs: [Need], canonicalList: GroceryList?) -> [Need] {
        let counts = Dictionary(grouping: needs, by: \.id).mapValues(\.count)
        return needs.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                matches($0, canonicalList: canonicalList)
        }
    }

    static func validClearOperations(
        _ operations: [ClearOperation],
        canonicalList: GroceryList?
    ) -> [ClearOperation] {
        guard let canonicalList, let household = canonicalList.household,
              let persistentStore = canonicalList.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: operations, by: \.id).mapValues(\.count)
        return operations.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.list == canonicalList && $0.household == household &&
                $0.objectID.persistentStore == persistentStore
        }
    }

    static func needsStore(_ need: Need) -> Bool {
        guard let household = need.list?.household else { return true }
        let tags: Set<Store>
        let anyStore: Bool
        if let item = need.item {
            tags = item.stores ?? []
            anyStore = item.anyStore
        } else if need.kind == NeedKind.oneTime.rawValue {
            tags = need.oneTimeStores ?? []
            anyStore = need.oneTimeAnyStore
        } else {
            return true
        }
        return !anyStore && !tags.isEmpty && !tags.contains {
            !$0.isArchived && $0.id != PersistenceModel.unsetID &&
                $0.household == household && $0.objectID.persistentStore == household.objectID.persistentStore
        }
    }

    static func needsStore(_ need: Need, activeStores: [Store]) -> Bool {
        let anyStore: Bool
        let tags: Set<Store>
        if let item = need.item {
            anyStore = item.anyStore
            tags = item.stores ?? []
        } else if need.kind == NeedKind.oneTime.rawValue {
            anyStore = need.oneTimeAnyStore
            tags = need.oneTimeStores ?? []
        } else {
            return true
        }
        return !anyStore && !tags.isEmpty && activeStores.allSatisfy { !tags.contains($0) }
    }

    static func matches(_ need: Need, canonicalList: GroceryList?) -> Bool {
        guard let canonicalList else { return false }
        return need.list == canonicalList &&
            need.objectID.persistentStore == canonicalList.objectID.persistentStore
    }
}

enum GroceryDestination: Hashable { case carted, recentlyCleared }

enum GroceryPurchaseRuleLabel {
    static func text(anyStore: Bool, stores: Set<Store>, activeStores: [Store]) -> String? {
        let names = activeStores.filter { stores.contains($0) }.map(\.name).sorted()
        if anyStore {
            return names.isEmpty ? "Buy at any store" : "Buy at any store · Also: \(names.joined(separator: ", "))"
        }
        guard !names.isEmpty else { return nil }
        return names.count == 1 ? "Only buy at \(names[0])" : "Buy at \(names.joined(separator: ", "))"
    }
}

struct SwipeRemovalTarget {
    let needID: UUID
    let revision: Int64
    let householdID: UUID
    let listID: UUID
    let name: String
}
