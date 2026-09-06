import CoreData

protocol HistoryCheckpointStore {
    func load(for storeIdentifier: String) throws -> NSPersistentHistoryToken?
    func save(_ token: NSPersistentHistoryToken, for storeIdentifier: String) throws
}

struct FileHistoryCheckpointStore: HistoryCheckpointStore {
    let directory: URL

    func load(for storeIdentifier: String) throws -> NSPersistentHistoryToken? {
        let url = checkpointURL(storeIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    func save(_ token: NSPersistentHistoryToken, for storeIdentifier: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        try data.write(to: checkpointURL(storeIdentifier), options: .atomic)
    }

    private func checkpointURL(_ identifier: String) -> URL {
        let safe = Data(identifier.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("history-\(safe).token")
    }
}

actor PersistentHistoryConsumer {
    private let persistence: PersistenceController
    private let checkpoints: HistoryCheckpointStore
    private var processing = false
    private var passRequested = false
    private var waiters: [CheckedContinuation<Int, Error>] = []

    init(persistence: PersistenceController, checkpoints: HistoryCheckpointStore) {
        self.persistence = persistence
        self.checkpoints = checkpoints
    }

    @discardableResult
    func consume() async throws -> Int {
        passRequested = true
        if processing {
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        processing = true
        do {
            var total = 0
            while passRequested {
                passRequested = false
                total += try await consumeAllStores()
            }
            processing = false
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume(returning: total) }
            return total
        } catch {
            processing = false
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func consumeAllStores() async throws -> Int {
        var count = 0
        for binding in persistence.storeBindings {
            count += try await consume(role: binding.role, store: binding.store)
        }
        return count
    }

    private func consume(role: PersistenceStoreRole, store: NSPersistentStore) async throws -> Int {
        guard let identifier = store.identifier ?? (store.metadata[NSStoreUUIDKey] as? String) else {
            throw PersistenceSetupError.missingPersistentStoreIdentifier
        }
        let loadedToken = try? checkpoints.load(for: identifier)
        do {
            return try await fetchMergeAndCheckpoint(after: loadedToken, role: role, store: store)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSPersistentHistoryTokenExpiredError {
            return try await fetchMergeAndCheckpoint(after: nil, role: role, store: store)
        }
    }

    private func fetchMergeAndCheckpoint(
        after token: NSPersistentHistoryToken?,
        role: PersistenceStoreRole,
        store: NSPersistentStore
    ) async throws -> Int {
        let context = persistence.container.newBackgroundContext()
        context.name = "Shopping history consumer \(role.rawValue)"
        let transactions: [NSPersistentHistoryTransaction] = try await context.perform {
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
            request.affectedStores = [store]
            guard let result = try context.execute(request) as? NSPersistentHistoryResult else { return [] }
            return result.result as? [NSPersistentHistoryTransaction] ?? []
        }
        let relevant = transactions.filter { $0.author != PersistenceController.commandAuthor }
        for transaction in relevant {
            await persistence.container.viewContext.perform {
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: transaction.objectIDNotification().userInfo ?? [:],
                    into: [self.persistence.container.viewContext]
                )
            }
        }
        if let token = transactions.last?.token {
            try checkpoints.save(token, for: store.identifier)
        }
        if transactions.isEmpty {
            await persistence.container.viewContext.perform { self.persistence.container.viewContext.refreshAllObjects() }
        }
        return relevant.count
    }
}
