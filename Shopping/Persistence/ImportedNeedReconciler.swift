import CloudKit
import CoreData

/// Owns reconciliation of physical copies of one occurrence, separately from grocery policy.
final class ImportedNeedReconciler {
    typealias RecordIdentity = (NSManagedObjectID) -> CKRecord.ID?
    typealias SyncBoundary = (NSManagedObjectContext, NSPersistentStore) throws -> Date?

    private let persistence: PersistenceController
    private let recordIdentity: RecordIdentity
    private let syncBoundary: SyncBoundary

    init(persistence: PersistenceController, recordIdentity: RecordIdentity? = nil, syncBoundary: SyncBoundary? = nil) {
        self.persistence = persistence
        self.recordIdentity = recordIdentity ?? { id in
            guard let store = id.persistentStore, persistence.role(of: store) == .ownerPrivate,
                  let cloud = persistence.container as? NSPersistentCloudKitContainer else { return nil }
            return cloud.recordID(for: id)
        }
        self.syncBoundary = syncBoundary ?? { context, store in
            guard persistence.role(of: store) == .ownerPrivate,
                  persistence.container is NSPersistentCloudKitContainer else { return nil }
            let fetch = NSPersistentCloudKitContainerEventRequest.fetchForEvents()
            fetch.fetchLimit = 200
            fetch.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
            let request = NSPersistentCloudKitContainerEventRequest.fetchEvents(matchingFetch: fetch)
            request.affectedStores = [store]
            // Missing/failed event evidence defers cleanup; it is not a history failure.
            let result = (try? context.execute(request)) as? NSPersistentCloudKitContainerEventResult
            let events = (result?.result as? [NSPersistentCloudKitContainer.Event] ?? [])
                .map { event in
                    CloudSyncStatus.Event(identifier: event.identifier, store: event.storeIdentifier,
                        operation: event.type == .import ? .download : event.type == .export ? .upload : .setup,
                        started: event.startDate, ended: event.endDate, failure: event.succeeded ? nil : .unknown)
                }
            return Self.settledThrough(events: events, storeIdentifier: store.identifier)
        }
    }

    static func settledThrough(events: [CloudSyncStatus.Event], storeIdentifier: String) -> Date? {
        let matching = events.filter { $0.store == storeIdentifier }
        let imports = matching.filter { $0.operation == .download }.max { $0.started < $1.started }
        let exports = matching.filter { $0.operation == .upload }.max { $0.started < $1.started }
        guard let imports, imports.failure == nil, imports.ended != nil,
              let exports, exports.failure == nil, exports.ended != nil else { return nil }
        return min(imports.started, exports.started)
    }

    @discardableResult
    func reconcile(in store: NSPersistentStore) async throws -> Bool {
        try await persistence.writer.perform {
            let context = self.persistence.writer
            let session = try self.persistence.personalCartSessionProvider?.currentSession()
            try self.validateAuthority(store: store, session: session)
            context.reset()
            let author = context.transactionAuthor
            context.transactionAuthor = "app.need-reconciliation"
            defer { context.transactionAuthor = author }
            do {
                // Scan on startup as well as import: a prior version may already have
                // checkpointed the transaction that introduced a duplicate.
                let request = Need.fetchRequest()
                request.affectedStores = [store]
                let groups = Dictionary(grouping: try context.fetch(request), by: \.id)
                    .filter { $0.key != PersistenceModel.unsetID && $0.value.count > 1 }
                guard !groups.isEmpty else { return false }
                guard let settledThrough = try self.syncBoundary(context, store) else { return true }
                var remaining = groups.count
                let historyRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
                historyRequest.affectedStores = [store]
                let history = try context.execute(historyRequest) as? NSPersistentHistoryResult
                var lastChanged: [NSManagedObjectID: Date] = [:]
                for transaction in history?.result as? [NSPersistentHistoryTransaction] ?? [] {
                    for change in transaction.changes ?? [] where change.changedObjectID.entity.name == "Need" {
                        lastChanged[change.changedObjectID] = max(lastChanged[change.changedObjectID] ?? .distantPast, transaction.timestamp)
                    }
                }
                for (id, copies) in groups where id != PersistenceModel.unsetID && copies.count > 1 {
                    // Relationships may arrive after the row itself. Wait for both
                    // import and export cycles that started after every copy's latest change.
                    guard copies.allSatisfy({ lastChanged[$0.objectID].map { $0 < settledThrough } ?? false }) else { continue }
                    guard let first = copies.first, self.hasResolvedScope(first, store: store),
                          copies.dropFirst().allSatisfy({ self.equivalent(first, $0) }) else { continue }
                    let records = copies.compactMap { need -> (Need, CKRecord.ID)? in
                        self.recordIdentity(need.objectID).map { (need, $0) }
                    }
                    // Never use local object IDs: their ordering differs on other replicas.
                    guard records.count == copies.count,
                          Set(records.map { $0.1 }).count == copies.count,
                          Set(records.map { $0.1.zoneID }).count == 1 else { continue }
                    remaining -= 1
                    for (duplicate, _) in records.sorted(by: { $0.1.recordName < $1.1.recordName }).dropFirst() {
                        context.delete(duplicate)
                    }
                }
                guard context.hasChanges else { return remaining > 0 }
                try self.persistence.prepareForSave(context)
                try self.validateAuthority(store: store, session: session)
                try context.save()
                return remaining > 0
            } catch {
                context.rollback()
                // Cleanup is optional; a Home that no longer permits writes must
                // not prevent imports for other Homes from being merged/checkpointed.
                if case PersistencePermissionError.updateDenied = error { return true }
                if case PersistencePermissionError.deleteDenied = error { return true }
                if case HomeDeletionError.scopeChanged = error { return true }
                throw error
            }
        }
    }

    private func validateAuthority(store: NSPersistentStore, session: ShopperSession?) throws {
        guard persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              session?.accountBinding == persistence.personalCartInitialBinding,
              try persistence.personalCartSessionProvider?.currentSession() == session else {
            throw PersonalCartError.accountChanged
        }
    }

    private func hasResolvedScope(_ need: Need, store: NSPersistentStore) -> Bool {
        guard let list = need.list, let household = list.household,
              list.id != PersistenceModel.unsetID, household.id != PersistenceModel.unsetID,
              household.groceryList == list,
              list.objectID.persistentStore == store, household.objectID.persistentStore == store,
              NeedUrgency(rawValue: need.urgency) != nil else { return false }
        switch NeedKind(rawValue: need.kind) {
        case .remembered:
            guard let item = need.item, item.id != PersistenceModel.unsetID,
                  item.household == household, item.objectID.persistentStore == store else { return false }
        case .oneTime:
            guard need.item == nil else { return false }
        default: return false
        }
        return true
    }

    private func equivalent(_ lhs: Need, _ rhs: Need) -> Bool {
        // Compare every persisted field, including optional quantities, cart flags,
        // revision and recovery IDs. Future model fields participate automatically.
        for key in lhs.entity.attributesByName.keys {
            if (lhs.value(forKey: key) as? NSObject) != (rhs.value(forKey: key) as? NSObject) { return false }
        }
        for (key, relationship) in lhs.entity.relationshipsByName {
            guard relationship.deleteRule == .nullifyDeleteRule,
                  (lhs.value(forKey: key) as? NSObject) == (rhs.value(forKey: key) as? NSObject) else { return false }
        }
        return true
    }
}
