import CoreData

enum PersistenceSetupError: Error {
    case missingPrimaryStoreURL
}

final class PersistenceController {
    let container: NSPersistentContainer
    let writer: NSManagedObjectContext

    init(storeURL: URL? = nil, additionalStoreURLs: [URL] = [], inMemory: Bool = false) throws {
        guard storeURL != nil || additionalStoreURLs.isEmpty else {
            throw PersistenceSetupError.missingPrimaryStoreURL
        }
        // This harness intentionally uses a local container; managed CloudKit stores are installed later.
        container = NSPersistentContainer(
            name: PersistenceModel.name,
            managedObjectModel: PersistenceModel.make()
        )

        let urls = storeURL.map { [$0] + additionalStoreURLs } ?? []
        let descriptions = (urls.isEmpty ? [nil] : urls.map(Optional.some)).map { url -> NSPersistentStoreDescription in
            let description = NSPersistentStoreDescription()
            description.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
            description.url = url
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.shouldAddStoreAsynchronously = false
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            return description
        }
        container.persistentStoreDescriptions = descriptions

        var loadError: Error?
        container.loadPersistentStores { _, error in
            if let error, loadError == nil {
                loadError = error
            }
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
