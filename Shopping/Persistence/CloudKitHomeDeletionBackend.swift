import CloudKit
import CoreData
import Foundation

protocol HomeDeletionBackend: Sendable {
    func share(for scope: ActiveHomeScope) async throws -> HomeEffectShare?
    func validatedCoverage(_ command: HomeDeletionCommand, knownObjectURIs: Set<String>) async throws -> Set<String>
    func purge(_ command: HomeDeletionCommand, coveredObjectURIs: Set<String>) async throws
    func zoneExists(_ command: HomeDeletionCommand) async throws -> Bool
}

/// Uses managed zone deletion only for an existing, exclusively owned home share.
final class CloudKitHomeDeletionBackend: HomeDeletionBackend, @unchecked Sendable {
    private let persistence: PersistenceController
    private let cart: PersonalCartService
    init(persistence: PersistenceController, cart: PersonalCartService) {
        self.persistence = persistence
        self.cart = cart
    }

    func share(for scope: ActiveHomeScope) async throws -> HomeEffectShare? {
        let share = try await localShare(for: scope)
        if let share {
            let target = try environment(scope)
            let record = try await CKContainer(identifier: scope.containerIdentifier).privateCloudDatabase.record(for:
                CKRecord.ID(recordName: share.recordName, zoneID: Self.zone(share)))
            guard let current = record as? CKShare, current.currentUserParticipant?.role == .owner,
                  current.recordID.zoneID == Self.zone(share), try environment(scope).store === target.store else {
                throw HomeDeletionError.ownerRequired
            }
        }
        return share
    }

    private func localShare(for scope: ActiveHomeScope) async throws -> HomeEffectShare? {
        let target = try environment(scope)
        guard let cloud = target.cloud else { return nil }
        let context = cloud.newBackgroundContext()
        return try await context.perform {
            _ = try self.environment(scope)
            let root = try HomeDeletionService.root(scope.graph, store: target.store, context: context)
            let objects = try HomeShareGraphValidator.objects(root: root, listID: scope.graph.listID, in: context)
            let mapped = try cloud.fetchShares(matching: objects.map(\.objectID))
            let intent = try HomeShareProvisioningJournal(url: HomeShareProvisioningJournal.location(
                storeURL: target.store.url!, scope: scope)).existingIntent(scope: scope)
            guard let share = mapped[root.objectID] else {
                guard mapped.isEmpty, intent?.attempted != true, intent?.identity == nil else { throw HomeDeletionError.sharingPending }
                return nil
            }
            guard share.currentUserParticipant?.role == .owner, share.publicPermission == .none else { throw HomeDeletionError.ownerRequired }
            guard mapped.count == objects.count, mapped.values.allSatisfy({ $0.recordID == share.recordID }) else {
                throw HomeDeletionError.sharingPending
            }
            // A zone purge must not include another graph or any private semantic evidence.
            let graphIDs = Set(objects.map(\.objectID))
            for entity in HomeShareGraphValidator.sharedEntities.union(["PersonalCartRecord", "LegacyCartReview"]) {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: entity)
                request.resultType = .managedObjectIDResultType
                request.affectedStores = [target.store]
                let ids = try context.fetch(request)
                let shares = try cloud.fetchShares(matching: ids)
                let records = cloud.recordIDs(for: ids)
                for (id, record) in records where record.zoneID == share.recordID.zoneID {
                    guard graphIDs.contains(id) else { throw HomeDeletionError.invalidGraph }
                }
                for (id, candidate) in shares where candidate.recordID.zoneID == share.recordID.zoneID {
                    guard graphIDs.contains(id) else { throw HomeDeletionError.invalidGraph }
                }
            }
            return HomeEffectShare(recordName: share.recordID.recordName,
                zoneName: share.recordID.zoneID.zoneName, zoneOwnerName: share.recordID.zoneID.ownerName)
        }
    }

    func purge(_ command: HomeDeletionCommand, coveredObjectURIs: Set<String>) async throws {
        guard let scope = command.scope, let share = command.share else { throw HomeDeletionError.ownerRequired }
        let target = try environment(scope)
        guard let cloud = target.cloud, target.store.url?.standardizedFileURL == command.storeURL.standardizedFileURL else {
            throw HomeDeletionError.scopeChanged
        }
        let validated = try await validateLocalZone(command, knownObjectURIs: coveredObjectURIs, target: target)
        guard validated.isSubset(of: coveredObjectURIs) else { throw HomeDeletionError.scopeChanged }
        let zone = Self.zone(share)
        // Server ownership was checked before the submitted checkpoint. From here,
        // a failure is uncertain and must be reconciled, not blindly retried.
        let returned: CKRecordZone.ID = try await withCheckedThrowingContinuation { continuation in
            cloud.purgeObjectsAndRecordsInZone(with: zone, in: target.store) { returned, error in
                if let error { continuation.resume(throwing: error) }
                else if let returned { continuation.resume(returning: returned) }
                else { continuation.resume(throwing: HomeDeletionError.outcomeUncertain) }
            }
        }
        guard returned == zone, try environment(scope).store === target.store else { throw HomeDeletionError.outcomeUncertain }
    }

    func zoneExists(_ command: HomeDeletionCommand) async throws -> Bool {
        guard let scope = command.scope, let share = command.share else { throw HomeDeletionError.ownerRequired }
        let target = try environment(scope)
        let exists: Bool
        do {
            let zone = try await CKContainer(identifier: scope.containerIdentifier).privateCloudDatabase.recordZone(for: Self.zone(share))
            guard zone.zoneID == Self.zone(share) else { throw HomeDeletionError.scopeChanged }
            exists = true
        } catch let error as CKError where error.code == .zoneNotFound { exists = false }
        guard try environment(scope).store === target.store else { throw HomeDeletionError.scopeChanged }
        return exists
    }

    func validatedCoverage(_ command: HomeDeletionCommand, knownObjectURIs: Set<String>) async throws -> Set<String> {
        guard let scope = command.scope, let share = command.share else { throw HomeDeletionError.ownerRequired }
        let target = try environment(scope)
        let record = try await CKContainer(identifier: scope.containerIdentifier).privateCloudDatabase.record(for:
            CKRecord.ID(recordName: share.recordName, zoneID: Self.zone(share)))
        guard let current = record as? CKShare, current.currentUserParticipant?.role == .owner,
              current.publicPermission == .none, current.recordID.zoneID == Self.zone(share),
              try environment(scope).store === target.store else { throw HomeDeletionError.ownerRequired }
        return try await validateLocalZone(command, knownObjectURIs: knownObjectURIs, target: target)
    }

    /// Native purge may remove the local root before its server callback is known.
    /// Retry still requires the captured owner share and no foreign local zone objects.
    private func validateLocalZone(_ command: HomeDeletionCommand, knownObjectURIs: Set<String>,
                                   target: (cloud: NSPersistentCloudKitContainer?, store: NSPersistentStore)) async throws -> Set<String> {
        guard let cloud = target.cloud, let scope = command.scope, let share = command.share,
              target.store.url?.standardizedFileURL == command.storeURL.standardizedFileURL else { throw HomeDeletionError.scopeChanged }
        let context = cloud.newBackgroundContext()
        return try await context.perform {
            _ = try self.environment(scope)
            var covered = knownObjectURIs
            if let root = try HomeDeletionService.remainingRoot(command.graph, store: target.store, context: context),
               root.groceryList != nil {
                let graph = try HomeShareGraphValidator.objects(root: root, listID: command.graph.listID, in: context)
                covered.formUnion(graph.map { $0.objectID.uriRepresentation().absoluteString })
            }
            for entity in HomeShareGraphValidator.sharedEntities.union(["PersonalCartRecord", "LegacyCartReview"]) {
                let request = NSFetchRequest<NSManagedObjectID>(entityName: entity)
                request.resultType = .managedObjectIDResultType
                request.affectedStores = [target.store]
                let ids = try context.fetch(request)
                let mapped = try cloud.fetchShares(matching: ids)
                let records = cloud.recordIDs(for: ids)
                for id in ids {
                    let uri = id.uriRepresentation().absoluteString
                    if covered.contains(uri) {
                        if let record = records[id], record.zoneID != Self.zone(share) { throw HomeDeletionError.scopeChanged }
                        if let current = mapped[id] {
                            guard current.recordID.zoneID == Self.zone(share) else { throw HomeDeletionError.scopeChanged }
                        } else {
                            // Native partial purge can retire local share metadata.
                            // Only previously verified coverage survives that absence.
                            guard knownObjectURIs.contains(uri) else { throw HomeDeletionError.scopeChanged }
                        }
                    }
                    if let candidate = mapped[id], candidate.recordID.zoneID == Self.zone(share) {
                        guard HomeShareGraphValidator.sharedEntities.contains(entity), covered.contains(uri) else {
                            throw HomeDeletionError.invalidGraph
                        }
                    }
                    if records[id]?.zoneID == Self.zone(share) {
                        guard HomeShareGraphValidator.sharedEntities.contains(entity), covered.contains(uri) else {
                            throw HomeDeletionError.invalidGraph
                        }
                    }
                }
            }
            return covered
        }
    }

    private func environment(_ scope: ActiveHomeScope) throws -> (cloud: NSPersistentCloudKitContainer?, store: NSPersistentStore) {
        let session = try cart.sessionProvider.currentSession()
        guard cart.persistence === persistence, cart.initialAccountBinding == session.accountBinding,
              persistence.personalCartInitialBinding == session.accountBinding,
              ActiveHomeScope(session: session, graph: scope.graph) == scope,
              let store = persistence.primaryStore, store.identifier == scope.graph.storeIdentifier, store.url != nil,
              persistence.role(of: store) != .participantShared,
              persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }) else {
            throw HomeDeletionError.scopeChanged
        }
        if case .local = persistence.configuration { return (nil, store) }
        guard case .managed(let privateURL, _, let identifier) = persistence.configuration,
              identifier == scope.containerIdentifier, store.url == privateURL,
              privateURL.deletingLastPathComponent().lastPathComponent == scope.accountBinding,
              persistence.role(of: store) == .ownerPrivate,
              let cloud = persistence.container as? NSPersistentCloudKitContainer,
              let description = cloud.persistentStoreDescriptions.first(where: { $0.url == privateURL }),
              description.cloudKitContainerOptions?.databaseScope == .private,
              description.cloudKitContainerOptions?.containerIdentifier == identifier else { throw HomeDeletionError.ownerRequired }
        return (cloud, store)
    }

    private static func zone(_ share: HomeEffectShare) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: share.zoneName, ownerName: share.zoneOwnerName)
    }
}
