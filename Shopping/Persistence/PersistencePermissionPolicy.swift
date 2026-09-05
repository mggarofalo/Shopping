import CoreData

enum PersistencePermissionError: Error, Equatable {
    case unresolvedStore
    case insertDenied
    case updateDenied
    case deleteDenied
}

protocol PersistencePermissionPolicy {
    func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws
}

struct LocalPersistencePermissionPolicy: PersistencePermissionPolicy {
    func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {}
}

struct DenyPersistencePermissionPolicy: PersistencePermissionPolicy {
    func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {
        guard !context.insertedObjects.isEmpty || !context.updatedObjects.isEmpty || !context.deletedObjects.isEmpty else { return }
        throw PersistencePermissionError.updateDenied
    }
}

struct ManagedPersistencePermissionPolicy: PersistencePermissionPolicy {
    func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {
        guard let cloud = controller.container as? NSPersistentCloudKitContainer else {
            throw PersistencePermissionError.unresolvedStore
        }
        for object in context.insertedObjects {
            guard let store = object.objectID.persistentStore else { throw PersistencePermissionError.unresolvedStore }
            guard cloud.canModifyManagedObjects(in: store) else { throw PersistencePermissionError.insertDenied }
        }
        for object in context.updatedObjects where !context.insertedObjects.contains(object) {
            guard cloud.canUpdateRecord(forManagedObjectWith: object.objectID) else {
                throw PersistencePermissionError.updateDenied
            }
        }
        for object in context.deletedObjects {
            guard cloud.canDeleteRecord(forManagedObjectWith: object.objectID) else {
                throw PersistencePermissionError.deleteDenied
            }
        }
    }
}
