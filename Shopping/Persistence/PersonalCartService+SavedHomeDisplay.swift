import CoreData

extension PersonalCartService {
    /// Resolve against all known homes so a filtered saved-cart view cannot
    /// give the same graph a different label. The writer returns values only.
    func savedCartHomeDisplays(for scopes: [PersonalCartScopeSnapshot]) async throws -> [SavedCartHomeDisplay] {
        try await Task.detached(priority: .utility) {
            let retained = try self.retainedScopes()
            return try self.transact(save: false) { repository in
                let deletions = try repository.homeDeletions()
                let roots = try repository.context.fetch(Household.fetchRequest())
                let lists = try repository.context.fetch(GroceryList.fetchRequest())
                let rootsByID = Dictionary(grouping: roots, by: \.id)
                let listsByID = Dictionary(grouping: lists, by: \.id)
                let validRoots = roots.compactMap { root -> (PersonalCartScopeSnapshot, HomePresentationSource)? in
                    guard rootsByID[root.id]?.count == 1,
                          !root.objectID.isTemporaryID, let list = root.groceryList,
                          listsByID[list.id]?.count == 1,
                          !list.objectID.isTemporaryID, let store = root.objectID.persistentStore,
                          list.objectID.persistentStore === store, list.household == root,
                          self.persistence.role(of: store) != nil,
                          let name = Self.usableHomeName(root.name) else { return nil }
                    let role: HomePresentationSource.Role
                    switch self.persistence.role(of: store) {
                    case .local: role = .local
                    case .ownerPrivate: role = .owner
                    case .participantShared:
                        if let cloud = self.persistence.container as? NSPersistentCloudKitContainer {
                            role = cloud.canUpdateRecord(forManagedObjectWith: root.objectID) ? .member : .readOnly
                        } else { role = .unknown }
                    case nil: role = .unknown
                    }
                    let scope = PersonalCartScopeSnapshot(householdID: root.id, listID: list.id)
                    return (scope, HomePresentationSource(scope: scope, name: name, role: role))
                }
                let rootsByScope = Dictionary(grouping: validRoots, by: { $0.0 })
                let allScopes = Set(scopes).union(retained).union(rootsByScope.keys)
                let sources = allScopes.map { scope -> HomePresentationSource in
                    let matchingDeletions = deletions.filter {
                        $0.command.graph.householdID == scope.householdID
                            && $0.command.graph.listID == scope.listID
                    }
                    if !matchingDeletions.isEmpty {
                        if matchingDeletions.count == 1,
                           let name = Self.usableHomeName(matchingDeletions[0].command.homeName) {
                            return HomePresentationSource(scope: scope, name: name, role: .owner)
                        }
                        return HomePresentationSource(scope: scope, name: "Saved Home", role: .unknown)
                    }
                    if let matches = rootsByScope[scope], matches.count == 1 {
                        return matches[0].1
                    }
                    return HomePresentationSource(scope: scope, name: "Saved Home", role: .unknown)
                }
                let presented = HomePresentationNames.resolve(sources)
                return scopes.map { scope in
                    let name = presented[scope] ?? HomePresentationName(name: "Saved Home", context: nil)
                    return SavedCartHomeDisplay(scope: scope, name: name.name, context: name.context)
                }
            }
        }.value
    }

    private static func usableHomeName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
