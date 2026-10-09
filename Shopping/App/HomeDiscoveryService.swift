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
                var access: HomeCandidate.Access
                switch persistence.role(of: store) {
                case .local, .ownerPrivate: access = .owner
                case .participantShared:
                    if let cloud = persistence.container as? NSPersistentCloudKitContainer {
                        access = cloud.canUpdateRecord(forManagedObjectWith: root.objectID)
                            && cloud.canUpdateRecord(forManagedObjectWith: list.objectID) ? .contributor : .restricted
                    } else { access = .unresolved }
                case nil: access = .unresolved
                }
                if persistence.personalCartsEnabled, let provider = persistence.personalCartSessionProvider {
                    let session = try provider.currentSession()
                    guard session.accountBinding == persistence.personalCartInitialBinding else { throw PersonalCartError.accountChanged }
                    let repository = PersonalCartRepository(persistence: persistence, context: persistence.writer, session: session)
                    if try repository.isHomeDeleted(householdID: root.id, listID: list.id) { continue }
                    let retained = try repository.homeEffectAccess(householdID: root.id, listID: list.id)
                    if retained.requiresExplicitRejoin { access = .unresolved }
                    else if !retained.permitsPublication(retained.capturedAuthority) { access = .restricted }
                    if let native = try? repository.nativeCommandAccess(for: root) {
                        if native == .lost { access = .unresolved }
                        else if native == .readOnly, access != .unresolved { access = .restricted }
                    }
                }
                if persistence.role(of: store) == .local, let url = store.url {
                    let graph = HomeGraphIdentity(storeIdentifier: storeID, rootURI: root.objectID.uriRepresentation().absoluteString,
                        householdID: root.id, listID: list.id)
                    if try LocalHomeDeletionJournal(storeURL: url).blocksUse(graph) { continue }
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
