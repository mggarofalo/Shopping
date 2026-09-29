import CoreData

/// CloudKit traverses relationships when sharing. Validate the complete reachable graph,
/// including archived data, before giving Core Data any root to share.
enum HomeShareGraphValidator {
    enum Failure: Error, Equatable {
        case incompleteHome
        case foreignObject
        case privateObject
        case ambiguousIdentity
        case unsupportedEntity(String)
    }

    static let sharedEntities: Set<String> = [
        "Household", "GroceryList", "Store", "Category", "Person", "Item", "Need", "ClearOperation", "HouseholdCartRecord"
    ]

    /// Call only on the supplied context's queue. Returned objects never leave that queue.
    static func objects(root: Household, listID: UUID, in context: NSManagedObjectContext) throws -> [NSManagedObject] {
        guard root.managedObjectContext === context, !root.isDeleted,
              !root.objectID.isTemporaryID, let store = root.objectID.persistentStore,
              let list = root.groceryList, list.id == listID, list.household == root else {
            throw Failure.incompleteHome
        }
        var result: [NSManagedObject] = []
        var seen: Set<NSManagedObjectID> = []
        var identities: [String: Set<UUID>] = [:]
        var remaining: [NSManagedObject] = [root]
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        while let object = remaining.popLast() {
            guard seen.insert(object.objectID).inserted else { continue }
            let entity = object.entity.name ?? ""
            guard entity != "PersonalCartRecord", entity != "LegacyCartReview" else { throw Failure.privateObject }
            guard sharedEntities.contains(entity) else { throw Failure.unsupportedEntity(entity) }
            guard object.managedObjectContext === context, !object.isDeleted,
                  !object.objectID.isTemporaryID, object.objectID.persistentStore == store,
                  ShareAssociationScope.household(for: object) == root else { throw Failure.foreignObject }
            if let candidate = object as? GroceryList, candidate != list { throw Failure.foreignObject }
            if let need = object as? Need, need.list != list { throw Failure.foreignObject }
            guard let id = object.value(forKey: "id") as? UUID, id != zero,
                  identities[entity, default: []].insert(id).inserted else { throw Failure.ambiguousIdentity }
            for relationship in object.entity.relationshipsByName.values {
                if relationship.isToMany {
                    if let values = object.value(forKey: relationship.name) as? Set<NSManagedObject> {
                        remaining.append(contentsOf: values)
                    } else if let values = object.value(forKey: relationship.name) as? NSOrderedSet {
                        remaining.append(contentsOf: values.compactMap { $0 as? NSManagedObject })
                    }
                } else if let related = object.value(forKey: relationship.name) as? NSManagedObject {
                    remaining.append(related)
                }
            }
            result.append(object)
        }
        guard seen.contains(list.objectID) else { throw Failure.incompleteHome }
        return result
    }
}
