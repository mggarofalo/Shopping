import CoreData

enum PersonalCartPersistencePolicy {
    static let authorizedAccountKey = "Shopping.PersonalCart.AuthorizedAccount"

    static func validate(in context: NSManagedObjectContext, controller: PersistenceController) throws {
        let changed = context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects)
        for object in changed {
            if let record = object as? PersonalCartRecord {
                guard context.userInfo[authorizedAccountKey] as? String == record.accountBinding,
                      !record.accountBinding.isEmpty,
                      record.objectID.persistentStore == controller.primaryStore,
                      !context.deletedObjects.contains(record),
                      context.insertedObjects.contains(record) else {
                    throw PersonalCartError.permissionDenied
                }
            }
            if object is LegacyCartReview,
               object.objectID.persistentStore != controller.primaryStore {
                throw PersonalCartError.permissionDenied
            }
        }
    }
}
