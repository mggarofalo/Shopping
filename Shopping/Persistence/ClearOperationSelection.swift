import CoreData

enum ClearOperationSelection {
    static func valid(_ operations: [ClearOperation], list: GroceryList?) -> [ClearOperation] {
        guard let list, let household = list.household,
              let store = list.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: operations, by: \.id).mapValues(\.count)
        return operations.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1
                && $0.list == list && $0.household == household && $0.objectID.persistentStore == store
        }
    }
}
