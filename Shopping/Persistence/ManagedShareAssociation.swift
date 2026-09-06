import CloudKit
import CoreData

struct PendingShareAssociation: Codable, Equatable {
    let householdURI: URL
    var objectURIs: Set<URL>
}

protocol ShareAssociationJournal {
    func stagePrivateInserts(_ objects: Set<NSManagedObject>, controller: PersistenceController) throws
    func pending() throws -> [PendingShareAssociation]
    func acknowledge(householdURI: URL, objectURIs: Set<URL>) throws
}

final class FileShareAssociationJournal: ShareAssociationJournal {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func stagePrivateInserts(_ objects: Set<NSManagedObject>, controller: PersistenceController) throws {
        let grouped = Dictionary(grouping: objects.compactMap { object -> (URL, URL)? in
            guard let store = object.objectID.persistentStore,
                  controller.role(of: store) == .ownerPrivate,
                  let household = Self.household(for: object) else { return nil }
            return (household.objectID.uriRepresentation(), object.objectID.uriRepresentation())
        }, by: { $0.0 })
        guard !grouped.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var entries = try loadUnlocked()
        for (householdURI, values) in grouped {
            if let index = entries.firstIndex(where: { $0.householdURI == householdURI }) {
                entries[index].objectURIs.formUnion(values.map(\.1))
            } else {
                entries.append(PendingShareAssociation(householdURI: householdURI, objectURIs: Set(values.map(\.1))))
            }
        }
        try saveUnlocked(entries)
    }

    func pending() throws -> [PendingShareAssociation] {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked()
    }

    func acknowledge(householdURI: URL, objectURIs: Set<URL>) throws {
        lock.lock(); defer { lock.unlock() }
        var entries = try loadUnlocked()
        guard let index = entries.firstIndex(where: { $0.householdURI == householdURI }) else { return }
        entries[index].objectURIs.subtract(objectURIs)
        if entries[index].objectURIs.isEmpty { entries.remove(at: index) }
        try saveUnlocked(entries)
    }

    private func loadUnlocked() throws -> [PendingShareAssociation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PendingShareAssociation].self, from: Data(contentsOf: url))
    }

    private func saveUnlocked(_ entries: [PendingShareAssociation]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    private static func household(for object: NSManagedObject) -> Household? {
        switch object {
        case let household as Household: return household
        case let store as Store: return store.household
        case let category as Category: return category.household
        case let item as Item: return item.household
        case let list as GroceryList: return list.household
        case let need as Need: return need.list?.household
        case let operation as ClearOperation: return operation.household
        default: return nil
        }
    }
}

enum ManagedShareAssociationError: Error {
    case objectBelongsToDifferentShare(URL)
}

actor ManagedShareAssociationWorker {
    private let persistence: PersistenceController
    private let journal: ShareAssociationJournal
    private var processing = false
    private var passRequested = false
    private var waiters: [CheckedContinuation<Int, Error>] = []

    init(persistence: PersistenceController, journal: ShareAssociationJournal) {
        self.persistence = persistence
        self.journal = journal
    }

    @discardableResult
    func retryPending() async throws -> Int {
        passRequested = true
        if processing {
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        processing = true
        do {
            while passRequested {
                passRequested = false
                try await drainOnce()
            }
            let count = try journal.pending().reduce(0) { $0 + $1.objectURIs.count }
            processing = false
            let pending = waiters; waiters.removeAll()
            pending.forEach { $0.resume(returning: count) }
            return count
        } catch {
            processing = false
            let pending = waiters; waiters.removeAll()
            pending.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func drainOnce() async throws {
        guard let cloud = persistence.container as? NSPersistentCloudKitContainer,
              let privateStore = persistence.store(for: .ownerPrivate) else { return }
        var firstError: Error?
        for entry in try journal.pending() {
            guard let householdID = persistence.container.persistentStoreCoordinator
                .managedObjectID(forURIRepresentation: entry.householdURI),
                  householdID.persistentStore == privateStore else {
                try journal.acknowledge(householdURI: entry.householdURI, objectURIs: entry.objectURIs)
                continue
            }
            let context = persistence.container.newBackgroundContext()
            let householdExists = try await context.perform {
                do {
                    return try context.existingObject(with: householdID) is Household
                } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == NSManagedObjectReferentialIntegrityError {
                    return false
                }
            }
            guard householdExists else {
                try journal.acknowledge(householdURI: entry.householdURI, objectURIs: entry.objectURIs)
                continue
            }

            do {
                let householdShares = try cloud.fetchShares(matching: [householdID])
                guard let householdShare = householdShares[householdID] else { continue }
                let candidates = try await context.perform {
                    var idsByURI: [URL: NSManagedObjectID] = [:]
                    var staleURIs: Set<URL> = []
                    for uri in entry.objectURIs {
                        guard let id = self.persistence.container.persistentStoreCoordinator
                            .managedObjectID(forURIRepresentation: uri),
                              id.persistentStore == privateStore else {
                            staleURIs.insert(uri)
                            continue
                        }
                        do {
                            let object = try context.existingObject(with: id)
                            guard Self.household(for: object)?.objectID == householdID else { continue }
                            idsByURI[uri] = id
                        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                            && error.code == NSManagedObjectReferentialIntegrityError {
                            staleURIs.insert(uri)
                        }
                    }
                    return (idsByURI: idsByURI, staleURIs: staleURIs)
                }
                if !candidates.staleURIs.isEmpty {
                    try journal.acknowledge(
                        householdURI: entry.householdURI,
                        objectURIs: candidates.staleURIs
                    )
                }
                guard !candidates.idsByURI.isEmpty else { continue }

                let candidateShares = try cloud.fetchShares(matching: Array(candidates.idsByURI.values))
                var alreadyAssociated: Set<URL> = []
                var unassociated: [URL: NSManagedObjectID] = [:]
                for (uri, id) in candidates.idsByURI {
                    guard let candidateShare = candidateShares[id] else {
                        unassociated[uri] = id
                        continue
                    }
                    guard candidateShare.recordID == householdShare.recordID else {
                        throw ManagedShareAssociationError.objectBelongsToDifferentShare(uri)
                    }
                    alreadyAssociated.insert(uri)
                }
                if !alreadyAssociated.isEmpty {
                    try journal.acknowledge(
                        householdURI: entry.householdURI,
                        objectURIs: alreadyAssociated
                    )
                }
                guard !unassociated.isEmpty else { continue }

                let associatedURIs = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Set<URL>, Error>) in
                    context.perform {
                        var validURIs: Set<URL> = []
                        let objects = unassociated.compactMap { uri, id -> NSManagedObject? in
                            guard let object = try? context.existingObject(with: id),
                                  Self.household(for: object)?.objectID == householdID else { return nil }
                            validURIs.insert(uri)
                            return object
                        }
                        guard !objects.isEmpty else {
                            continuation.resume(returning: [])
                            return
                        }
                        cloud.share(objects, to: householdShare) { _, _, _, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume(returning: validURIs) }
                        }
                    }
                }
                if !associatedURIs.isEmpty {
                    try journal.acknowledge(
                        householdURI: entry.householdURI,
                        objectURIs: associatedURIs
                    )
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private static func household(for object: NSManagedObject) -> Household? {
        switch object {
        case let household as Household: return household
        case let store as Store: return store.household
        case let category as Category: return category.household
        case let item as Item: return item.household
        case let list as GroceryList: return list.household
        case let need as Need: return need.list?.household
        case let operation as ClearOperation: return operation.household
        default: return nil
        }
    }
}
