import CoreData

final class PersistenceController {
    let container: NSPersistentContainer
    let writer: NSManagedObjectContext

    init(storeURL: URL? = nil, inMemory: Bool = false) throws {
        // This harness intentionally uses a local container; managed CloudKit stores are installed later.
        container = NSPersistentContainer(
            name: PersistenceModel.name,
            managedObjectModel: PersistenceModel.make()
        )

        let description = NSPersistentStoreDescription()
        description.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
        if let storeURL {
            description.url = storeURL
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if let loadError {
            throw loadError
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        writer = container.newBackgroundContext()
        writer.name = "Shopping serial command writer"
        writer.transactionAuthor = "app.commands"
        writer.mergePolicy = NSErrorMergePolicy
        writer.undoManager = nil
    }

    func simulationContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.retainsRegisteredObjects = true
        return context
    }
}
