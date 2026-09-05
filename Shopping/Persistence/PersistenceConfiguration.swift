import CoreData

enum PersistenceStoreRole: String, Codable {
    case local
    case ownerPrivate
    case participantShared
}

struct PersistenceStoreConfiguration: Equatable {
    let role: PersistenceStoreRole
    let url: URL?
}

enum PersistenceConfiguration: Equatable {
    case local(storeURL: URL?, additionalStoreURLs: [URL] = [], inMemory: Bool = false)
    case managed(privateURL: URL, sharedURL: URL, containerIdentifier: String)

    var stores: [PersistenceStoreConfiguration] {
        switch self {
        case .local(let storeURL, let additional, _):
            let urls = storeURL.map { [$0] + additional } ?? []
            return urls.isEmpty
                ? [PersistenceStoreConfiguration(role: .local, url: nil)]
                : urls.map { PersistenceStoreConfiguration(role: .local, url: $0) }
        case .managed(let privateURL, let sharedURL, _):
            return [
                PersistenceStoreConfiguration(role: .ownerPrivate, url: privateURL),
                PersistenceStoreConfiguration(role: .participantShared, url: sharedURL)
            ]
        }
    }

    var isManaged: Bool {
        if case .managed = self { return true }
        return false
    }

    static func applicationLocal(fileManager: FileManager = .default) throws -> PersistenceConfiguration {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Shopping", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return .local(storeURL: base.appendingPathComponent("Shopping.sqlite"))
    }

    func makeDescriptions() -> [NSPersistentStoreDescription] {
        stores.map { store in
            let description = NSPersistentStoreDescription()
            if case .local(_, _, let inMemory) = self, inMemory {
                description.type = NSInMemoryStoreType
            } else {
                description.type = NSSQLiteStoreType
            }
            description.url = store.url
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.shouldAddStoreAsynchronously = false
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            if case .managed(_, _, let identifier) = self {
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
                options.databaseScope = store.role == .ownerPrivate ? .private : .shared
                description.cloudKitContainerOptions = options
            }
            return description
        }
    }
}
