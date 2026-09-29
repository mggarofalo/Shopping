import CoreData

/// Read on the serial writer, returning values only. No managed objects cross the queue.
final class HomeDiscoveryService: @unchecked Sendable {
    private let persistence: PersistenceController

    init(persistence: PersistenceController) { self.persistence = persistence }

    func discover() throws -> HomeDiscovery {
        try persistence.writer.performAndWait {
            persistence.writer.reset()
            let roots = try persistence.writer.fetch(Household.fetchRequest())
            let lists = try persistence.writer.fetch(GroceryList.fetchRequest())
            let rootCounts = Dictionary(grouping: roots, by: \.id)
            let listCounts = Dictionary(grouping: lists, by: \.id)
            var incomplete = lists.contains { $0.household == nil || $0.household?.groceryList != $0 }
            var homes: [HomeCandidate] = []
            let unsetID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            for root in roots {
                guard root.id != unsetID, rootCounts[root.id]?.count == 1, !root.objectID.isTemporaryID,
                      let store = root.objectID.persistentStore,
                      let storeID = store.identifier, !storeID.isEmpty,
                      let list = root.groceryList, list.id != unsetID, listCounts[list.id]?.count == 1,
                      list.household == root, list.objectID.persistentStore == store else {
                    incomplete = true
                    continue
                }
                let access: HomeCandidate.Access
                switch persistence.role(of: store) {
                case .local, .ownerPrivate: access = .owner
                case .participantShared:
                    if let cloud = persistence.container as? NSPersistentCloudKitContainer {
                        access = cloud.canUpdateRecord(forManagedObjectWith: root.objectID)
                            && cloud.canUpdateRecord(forManagedObjectWith: list.objectID) ? .contributor : .restricted
                    } else { access = .unresolved }
                case nil: access = .unresolved
                }
                homes.append(HomeCandidate(graph: HomeGraphIdentity(storeIdentifier: storeID,
                    rootURI: root.objectID.uriRepresentation().absoluteString,
                    householdID: root.id, listID: list.id), name: root.name, access: access))
            }
            return HomeDiscovery(homes: homes.sorted { $0.graph.rootURI < $1.graph.rootURI },
                hasIncompleteRoots: incomplete)
        }
    }
}
