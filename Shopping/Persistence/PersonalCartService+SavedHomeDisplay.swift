import CoreData

extension PersonalCartService {
    /// Reads only the requested exact roots/lists on the serial writer. The
    /// private ledger is the fallback once a deleted graph is gone.
    func savedCartHomeDisplays(for scopes: [PersonalCartScopeSnapshot]) async throws -> [SavedCartHomeDisplay] {
        try await Task.detached(priority: .utility) {
            try self.transact(save: false) { repository in
                let deletions = try repository.homeDeletions()
                return try scopes.map { scope in
                    let matchingDeletions = deletions.filter {
                        $0.command.graph.householdID == scope.householdID
                            && $0.command.graph.listID == scope.listID
                    }
                    if !matchingDeletions.isEmpty {
                        guard matchingDeletions.count == 1,
                              let name = Self.usableHomeName(matchingDeletions[0].command.homeName) else {
                            return .unknown(scope)
                        }
                        return SavedCartHomeDisplay(scope: scope, name: name)
                    }
                    let rootRequest = Household.fetchRequest()
                    rootRequest.predicate = NSPredicate(format: "id == %@", scope.householdID as CVarArg)
                    let listRequest = GroceryList.fetchRequest()
                    listRequest.predicate = NSPredicate(format: "id == %@", scope.listID as CVarArg)
                    let roots = try repository.context.fetch(rootRequest)
                    let lists = try repository.context.fetch(listRequest)
                    guard roots.count == 1, lists.count == 1,
                          let root = roots.first, let list = lists.first,
                          !root.objectID.isTemporaryID, !list.objectID.isTemporaryID,
                          let store = root.objectID.persistentStore,
                          self.persistence.role(of: store) != nil,
                          list.objectID.persistentStore === store,
                          root.groceryList == list, list.household == root,
                          let name = Self.usableHomeName(root.name) else { return .unknown(scope) }
                    return SavedCartHomeDisplay(scope: scope, name: name)
                }
            }
        }.value
    }

    private static func usableHomeName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
