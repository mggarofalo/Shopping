import CoreData
import SwiftUI

enum PurchaseRulesStoreScope {
    static func listsRequest() -> NSFetchRequest<GroceryList> {
        let request = GroceryList.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        return request
    }

    static func validStores(
        _ stores: [Store],
        lists: [GroceryList],
        householdID: UUID?,
        listID: UUID?
    ) -> [Store] {
        guard let householdID, let listID,
              householdID != PersistenceModel.unsetID, listID != PersistenceModel.unsetID else { return [] }
        let matchingLists = lists.filter { $0.id == listID }
        guard matchingLists.count == 1, let household = matchingLists[0].household,
              household.id == householdID,
              let persistentStore = household.objectID.persistentStore,
              matchingLists[0].objectID.persistentStore == persistentStore else { return [] }
        let counts = Dictionary(grouping: stores, by: \.id).mapValues(\.count)
        return stores.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }
}
