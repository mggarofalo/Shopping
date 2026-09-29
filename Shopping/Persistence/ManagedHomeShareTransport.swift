import CloudKit
import CoreData

/// Core Data owns all sharing writes. No direct record/zone creation or speculative purge.
final class ManagedHomeShareTransport: HomeShareTransport, @unchecked Sendable {
    private let persistence: PersistenceController
    private let authority: UICommandAuthority

    init(persistence: PersistenceController, authority: UICommandAuthority) {
        self.persistence = persistence
        self.authority = authority
    }

    func existingShare(for scope: ActiveHomeScope) async throws -> HomeShareIdentity? {
        let (cloud, store) = try environment(scope)
        let context = cloud.newBackgroundContext()
        return try await context.perform {
            _ = try self.environment(scope)
            let (root, objects) = try self.graph(scope, store: store, context: context)
            let share = try self.knownShare(root: root, objects: objects, cloud: cloud)
            try self.validatePrivateExclusion(cloud: cloud, context: context)
            _ = try self.environment(scope)
            return try share.map { try self.identity(of: $0) }
        }
    }

    func createShare(for scope: ActiveHomeScope) async throws -> HomeShareIdentity {
        let (cloud, store) = try environment(scope)
        let context = cloud.newBackgroundContext()
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    _ = try self.environment(scope)
                    let (root, objects) = try self.graph(scope, store: store, context: context)
                    try self.validatePrivateExclusion(cloud: cloud, context: context)
                    if let share = try self.knownShare(root: root, objects: objects, cloud: cloud) {
                        _ = try self.environment(scope)
                        continuation.resume(returning: try self.identity(of: share))
                        return
                    }
                    let title = root.name
                    _ = try self.environment(scope)
                    // Replays always use this same saved root. Core Data rejects objects
                    // already shared; an empty lookup is not proof of nonapplication.
                    cloud.share([root], to: nil) { _, share, _, error in
                        if let error { continuation.resume(throwing: error); return }
                        do {
                            _ = try self.environment(scope)
                            guard let share else { throw HomeSharingError.missingResult }
                            _ = try self.identity(of: share)
                            share.publicPermission = .none
                            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
                            let identity = try self.identity(of: share)
                            // This callback establishes share persistence, not household export.
                            cloud.persistUpdatedShare(share, in: store) { saved, error in
                                if let error { continuation.resume(throwing: error); return }
                                do {
                                    _ = try self.environment(scope)
                                    guard let saved else { throw HomeSharingError.missingResult }
                                    guard try self.identity(of: saved) == identity else { throw HomeSharingError.conflictingShare }
                                    NotificationCenter.default.post(name: PersistenceController.pendingShareAssociation, object: self.persistence)
                                    continuation.resume(returning: identity)
                                } catch { continuation.resume(throwing: error) }
                            }
                        } catch { continuation.resume(throwing: error) }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func environment(_ scope: ActiveHomeScope) throws -> (NSPersistentCloudKitContainer, NSPersistentStore) {
        try authority.validate()
        guard let provider = persistence.personalCartSessionProvider else { throw HomeSharingError.unavailable }
        let session = try provider.currentSession()
        guard session.accountBinding == scope.accountBinding,
              session.containerIdentifier == scope.containerIdentifier, session.environment == scope.environment,
              persistence.personalCartInitialBinding == scope.accountBinding else { throw HomeSharingError.scopeChanged }
        guard case .managed(_, _, let containerID) = persistence.configuration,
              containerID == scope.containerIdentifier,
              let cloud = persistence.container as? NSPersistentCloudKitContainer else { throw HomeSharingError.unavailable }
        guard let store = persistence.store(for: .ownerPrivate), store.identifier == scope.graph.storeIdentifier,
              cloud.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }) else {
            throw HomeSharingError.ownerRequired
        }
        return (cloud, store)
    }

    private func graph(_ scope: ActiveHomeScope, store: NSPersistentStore,
                       context: NSManagedObjectContext) throws -> (Household, [NSManagedObject]) {
        guard let uri = URL(string: scope.graph.rootURI),
              let id = persistence.container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri),
              id.persistentStore == store,
              let root = try context.existingObject(with: id) as? Household,
              root.id == scope.graph.householdID else { throw HomeSharingError.scopeChanged }
        let roots = Household.fetchRequest()
        roots.predicate = NSPredicate(format: "id == %@", scope.graph.householdID as CVarArg)
        let lists = GroceryList.fetchRequest()
        lists.predicate = NSPredicate(format: "id == %@", scope.graph.listID as CVarArg)
        guard try context.count(for: roots) == 1, try context.count(for: lists) == 1 else {
            throw HomeShareGraphValidator.Failure.ambiguousIdentity
        }
        return (root, try HomeShareGraphValidator.objects(root: root, listID: scope.graph.listID, in: context))
    }

    private func knownShare(root: Household, objects: [NSManagedObject], cloud: NSPersistentCloudKitContainer) throws -> CKShare? {
        let shares = try cloud.fetchShares(matching: objects.map(\.objectID))
        guard let share = shares[root.objectID] else {
            guard shares.isEmpty else { throw HomeSharingError.associationPending }
            return nil
        }
        _ = try identity(of: share)
        guard shares.values.allSatisfy({ $0.recordID == share.recordID }) else { throw HomeSharingError.conflictingShare }
        return share
    }

    private func validatePrivateExclusion(cloud: NSPersistentCloudKitContainer, context: NSManagedObjectContext) throws {
        for name in ["PersonalCartRecord", "LegacyCartReview"] {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: name)
            request.resultType = .managedObjectIDResultType
            let ids = try context.fetch(request)
            guard try cloud.fetchShares(matching: ids).isEmpty else { throw HomeShareGraphValidator.Failure.privateObject }
        }
    }

    private func identity(of share: CKShare) throws -> HomeShareIdentity {
        guard share.currentUserParticipant?.role == .owner else { throw HomeSharingError.ownerRequired }
        guard share.publicPermission == .none else { throw HomeSharingError.unexpectedPublicAccess }
        return HomeShareIdentity(recordName: share.recordID.recordName,
            zoneName: share.recordID.zoneID.zoneName, zoneOwnerName: share.recordID.zoneID.ownerName)
    }
}
