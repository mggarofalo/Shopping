import CoreData

enum PersistenceSetupError: LocalizedError {
    case missingPrimaryStoreURL
    case missingPersistentStoreIdentifier
    case storeLoadFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingPrimaryStoreURL:
            return "The primary persistent store URL is missing."
        case .missingPersistentStoreIdentifier:
            return "The persistent store has no stable identifier."
        case .storeLoadFailed(let error):
            return "The persistent store could not be loaded: \(error.localizedDescription)"
        }
    }
}

final class PersistenceController {
    static let pendingShareAssociation = Notification.Name("ShoppingPendingShareAssociation")
    struct StoreBinding {
        let role: PersistenceStoreRole
        let store: NSPersistentStore
    }
    static let commandAuthor = "app.commands"
    let container: NSPersistentContainer
    let writer: NSManagedObjectContext
    let configuration: PersistenceConfiguration
    let permissionPolicy: PersistencePermissionPolicy
    let shareAssociationJournal: ShareAssociationJournal?
    private(set) var storeBindings: [StoreBinding] = []

    convenience init(storeURL: URL? = nil, additionalStoreURLs: [URL] = [], inMemory: Bool = false) throws {
        guard storeURL != nil || additionalStoreURLs.isEmpty else {
            throw PersistenceSetupError.missingPrimaryStoreURL
        }
        try self.init(configuration: .local(storeURL: storeURL, additionalStoreURLs: additionalStoreURLs, inMemory: inMemory))
    }

    init(
        configuration: PersistenceConfiguration,
        permissionPolicy: PersistencePermissionPolicy? = nil,
        shareAssociationJournal: ShareAssociationJournal? = nil
    ) throws {
        self.configuration = configuration
        self.permissionPolicy = permissionPolicy ?? (configuration.isManaged
            ? ManagedPersistencePermissionPolicy()
            : LocalPersistencePermissionPolicy())
        if let shareAssociationJournal {
            self.shareAssociationJournal = shareAssociationJournal
        } else if case .managed(let privateURL, _, _) = configuration {
            self.shareAssociationJournal = FileShareAssociationJournal(
                url: privateURL.deletingLastPathComponent().appendingPathComponent("pending-share-associations.json")
            )
        } else {
            self.shareAssociationJournal = nil
        }
        let model = try PersistenceModel.make()
        if configuration.isManaged {
            container = NSPersistentCloudKitContainer(name: PersistenceModel.name, managedObjectModel: model)
        } else {
            container = NSPersistentContainer(name: PersistenceModel.name, managedObjectModel: model)
        }
        let descriptions = configuration.makeDescriptions()
        container.persistentStoreDescriptions = descriptions

        var loadError: Error?
        container.loadPersistentStores { _, error in
            if let error, loadError == nil {
                loadError = error
            }
        }
        if let loadError {
            throw PersistenceSetupError.storeLoadFailed(loadError)
        }

        var unmatched = container.persistentStoreCoordinator.persistentStores
        for configured in configuration.stores {
            guard let index = unmatched.firstIndex(where: { configured.url == nil || $0.url == configured.url }) else { continue }
            storeBindings.append(StoreBinding(role: configured.role, store: unmatched.remove(at: index)))
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.transactionAuthor = "app.view"

        writer = container.newBackgroundContext()
        writer.name = "Shopping serial command writer"
        writer.transactionAuthor = Self.commandAuthor
        writer.mergePolicy = NSErrorMergePolicy
        writer.undoManager = nil
    }

    var primaryStore: NSPersistentStore? {
        storeBindings.first(where: { $0.role == .local })?.store
            ?? storeBindings.first(where: { $0.role == .ownerPrivate })?.store
    }

    func role(of store: NSPersistentStore) -> PersistenceStoreRole? {
        storeBindings.first(where: { $0.store == store })?.role
    }

    func store(for role: PersistenceStoreRole) -> NSPersistentStore? {
        storeBindings.first(where: { $0.role == role })?.store
    }

    func prepareForSave(_ context: NSManagedObjectContext) throws {
        if !context.insertedObjects.isEmpty {
            try context.obtainPermanentIDs(for: Array(context.insertedObjects))
        }
        try permissionPolicy.validateChanges(in: context, controller: self)
        try shareAssociationJournal?.stagePrivateInserts(context.insertedObjects, controller: self)
    }

    func simulationContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.retainsRegisteredObjects = true
        return context
    }
}
