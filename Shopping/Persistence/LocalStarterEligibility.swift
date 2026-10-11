import CoreData
import Foundation

/// Eligibility reads are serialized with source writes and destructive cleanup.
enum LocalStarterEligibility {
    /// Called on the serial writer immediately after a newly inserted first Home
    /// commits. Replays and historical Homes never manufacture new provenance.
    static func capture(command: LocalHomeCreationCommand, persistence: PersistenceController,
                       context: NSManagedObjectContext) throws -> LocalStarterEvidence {
        guard let store = persistence.primaryStore, store.url != nil,
              store.identifier == command.storeIdentifier,
              persistence.role(of: store) == .local,
              persistence.personalCartSessionProvider == nil else { throw HomeDeletionError.scopeChanged }
        let roots = Household.fetchRequest()
        roots.affectedStores = [store]
        let root = try context.fetch(roots).first(where: { $0.id == command.householdID })
        guard let root, root.groceryList?.id == command.listID, root.name == command.name else {
            throw HomeDeletionError.scopeChanged
        }
        let graph = HomeGraphIdentity(storeIdentifier: command.storeIdentifier,
            rootURI: root.objectID.uriRepresentation().absoluteString,
            householdID: command.householdID, listID: command.listID)
        let value = LocalStarterEvidence(version: 1, creationID: command.id, graph: graph,
            name: command.name, transactionNumber: try latestTransaction(store: store, context: context))
        try validate(value, persistence: persistence, context: context)
        return value
    }

    /// Runs inside the deletion writer transaction, before retaining/submitting
    /// deletion. History catches same-object edits, including a rename and revert.
    static func validate(_ evidence: LocalStarterEvidence, persistence: PersistenceController,
                         context: NSManagedObjectContext) throws {
        let graph = evidence.graph
        guard evidence.version == 1, let store = persistence.primaryStore,
              persistence.role(of: store) == .local,
              persistence.personalCartSessionProvider == nil,
              store.identifier == graph.storeIdentifier, store.type == NSSQLiteStoreType,
              !(persistence.container is NSPersistentCloudKitContainer),
              try Self.latestTransaction(store: store, context: context) == evidence.transactionNumber else {
            throw HomeDeletionError.scopeChanged
        }
        let root = try HomeDeletionService.root(graph, store: store, context: context)
        guard root.name == evidence.name, let list = root.groceryList, list.household == root else {
            throw HomeDeletionError.scopeChanged
        }
        let allowed = Set([root.objectID, list.objectID])
        for entity in persistence.container.managedObjectModel.entities where !entity.isAbstract {
            guard let name = entity.name else { throw HomeDeletionError.invalidGraph }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.affectedStores = [store]
            request.includesSubentities = false
            guard try context.fetch(request).allSatisfy({ allowed.contains($0.objectID) }) else {
                throw HomeDeletionError.scopeChanged
            }
        }
    }

    private static func latestTransaction(store: NSPersistentStore, context: NSManagedObjectContext) throws -> Int64 {
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
        request.affectedStores = [store]
        guard let result = try context.execute(request) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction],
              let number = transactions.map(\.transactionNumber).max(), number > 0 else {
            throw HomeDeletionError.scopeChanged
        }
        return number
    }
}
