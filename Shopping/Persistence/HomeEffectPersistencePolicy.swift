import CoreData

/// Applies observed authority to every household command, including insertion of
/// new descendants. Private records deliberately have no household relationship.
enum HomeEffectPersistencePolicy {
    static func validate(in context: NSManagedObjectContext, controller: PersistenceController,
                         excluding authorizedDeletions: Set<NSManagedObjectID> = []) throws {
        guard controller.personalCartsEnabled, let provider = controller.personalCartSessionProvider else { return }
        let changed = context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects)
        var homes: Set<Household> = []
        for object in changed where !authorizedDeletions.contains(object.objectID) {
            if let home = ShareAssociationScope.household(for: object) { homes.insert(home) }
            // A relationship move cannot evade the original home's restriction.
            if object.entity.relationshipsByName["household"] != nil,
               let original = object.committedValues(forKeys: ["household"])["household"] as? Household {
                homes.insert(original)
            }
            if let need = object as? Need,
               let original = need.committedValues(forKeys: ["list"])["list"] as? GroceryList,
               let home = original.household { homes.insert(home) }
        }
        guard !homes.isEmpty else { return }
        let session = try provider.currentSession()
        guard session.accountBinding == controller.personalCartInitialBinding else { throw PersonalCartError.accountChanged }
        let repository = PersonalCartRepository(persistence: controller, context: context, session: session)
        for home in homes {
            guard let list = home.groceryList else { throw PersonalCartError.unavailable }
            let native = try repository.nativeCommandAccess(for: home)
            guard native != .readOnly, native != .lost else { throw PersistencePermissionError.updateDenied }
            let access = try repository.homeEffectAccess(householdID: home.id, listID: list.id)
            guard access.permitsPublication(access.capturedAuthority) else { throw PersistencePermissionError.updateDenied }
        }
    }
}
