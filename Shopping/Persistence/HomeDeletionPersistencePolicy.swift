import CoreData

/// Exact, queue-confined deletion authority, never a blanket permission bypass.
struct HomeDeletionSaveAuthority {
    let command: HomeDeletionCommand
    let objectIDs: Set<NSManagedObjectID>
    static let key = "Shopping.HomeDeletion.SaveAuthority"
}

enum HomeDeletionPersistencePolicy {
    static func authorizedDeletions(in context: NSManagedObjectContext, controller: PersistenceController) throws -> Set<NSManagedObjectID> {
        guard let authority = context.userInfo[HomeDeletionSaveAuthority.key] as? HomeDeletionSaveAuthority else { return [] }
        try authority.command.validate()
        let deleted = Set(context.deletedObjects.map(\.objectID))
        guard !deleted.isEmpty, deleted == authority.objectIDs,
              context.deletedObjects.allSatisfy({ HomeShareGraphValidator.sharedEntities.contains($0.entity.name ?? "")
                  && $0.objectID.persistentStore?.identifier == authority.command.graph.storeIdentifier }),
              !context.insertedObjects.contains(where: { !($0 is PersonalCartRecord) }),
              context.updatedObjects.allSatisfy({ deleted.contains($0.objectID) }) else { throw HomeDeletionError.invalidGraph }
        if let scope = authority.command.scope {
            guard let provider = controller.personalCartSessionProvider else { throw PersonalCartError.accountChanged }
            let session = try provider.currentSession()
            guard ActiveHomeScope(session: session, graph: scope.graph) == scope else { throw PersonalCartError.accountChanged }
            let repository = PersonalCartRepository(persistence: controller, context: context, session: session)
            guard try repository.homeDeletions().contains(where: { $0.command == authority.command }) else { throw HomeDeletionError.scopeChanged }
            guard try Set(deleted.map { $0.uriRepresentation().absoluteString }).isSubset(of: repository.homeDeletionObjectURIs(authority.command)) else {
                throw HomeDeletionError.invalidGraph
            }
        } else {
            guard Set(deleted.map { $0.uriRepresentation().absoluteString }) == authority.command.objectURIs else {
                throw HomeDeletionError.invalidGraph
            }
            guard try LocalHomeDeletionJournal(storeURL: authority.command.storeURL).contains(authority.command.graph) else {
                throw HomeDeletionError.scopeChanged
            }
        }
        return deleted
    }

    static func validateLocalChanges(in context: NSManagedObjectContext, controller: PersistenceController,
                                     excluding authorized: Set<NSManagedObjectID>) throws {
        for object in context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects)
            where !authorized.contains(object.objectID) {
            guard let home = ShareAssociationScope.household(for: object), let list = home.groceryList,
                  let store = home.objectID.persistentStore, controller.role(of: store) == .local,
                  let url = store.url, let storeID = store.identifier else { continue }
            let graph = HomeGraphIdentity(storeIdentifier: storeID, rootURI: home.objectID.uriRepresentation().absoluteString,
                householdID: home.id, listID: list.id)
            guard try !LocalHomeDeletionJournal(storeURL: url).contains(graph) else { throw HomeDeletionError.scopeChanged }
        }
    }
}
