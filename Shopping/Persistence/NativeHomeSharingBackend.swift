import CloudKit
import CoreData

/// The only sharing adapter that invokes SDK services. Domain graph policy stays outside.
final class NativeHomeSharingBackend: HomeSharingBackend, @unchecked Sendable {
    private final class Backing: HomeBackendShareBacking, @unchecked Sendable {
        let share: CKShare
        init(_ share: CKShare) { self.share = share }
    }

    private let persistence: PersistenceController
    private let privateRecords: PersonalCartService?

    init(persistence: PersistenceController, privateRecords: PersonalCartService? = nil) {
        self.persistence = persistence
        self.privateRecords = privateRecords
    }

    private func cloud() throws -> NSPersistentCloudKitContainer {
        guard let cloud = persistence.container as? NSPersistentCloudKitContainer else { throw HomeMembershipError.shareUnavailable }
        return cloud
    }

    func environment(scope: ActiveHomeScope) throws -> (NSPersistentStore, PersistenceStoreRole) {
        guard case .managed(let privateURL, let sharedURL, let containerID) = persistence.configuration,
              containerID == scope.containerIdentifier,
              let binding = persistence.storeBindings.first(where: { $0.store.identifier == scope.graph.storeIdentifier }),
              binding.role == .ownerPrivate || binding.role == .participantShared else { throw HomeMembershipError.shareUnavailable }
        let cloud = try cloud()
        let url = binding.role == .ownerPrivate ? privateURL : sharedURL
        guard cloud.persistentStoreCoordinator.persistentStores.contains(where: { $0 === binding.store }),
              binding.store.url == url, url.deletingLastPathComponent().lastPathComponent == scope.accountBinding,
              let description = cloud.persistentStoreDescriptions.first(where: { $0.url == url }),
              description.cloudKitContainerOptions?.containerIdentifier == containerID,
              description.cloudKitContainerOptions?.databaseScope == (binding.role == .ownerPrivate ? .private : .shared) else {
            throw HomeMembershipError.scopeChanged
        }
        return (binding.store, binding.role)
    }

    func associatedShares(_ ids: [NSManagedObjectID]) throws -> [NSManagedObjectID: HomeBackendShare] {
        let shares = try cloud().fetchShares(matching: ids)
        var observations: [CKRecord.ID: HomeBackendShare] = [:]
        var result: [NSManagedObjectID: HomeBackendShare] = [:]
        for (objectID, share) in shares {
            if let observed = observations[share.recordID] {
                result[objectID] = observed
            } else {
                let observed = try Self.observation(share, includeInvitationURLs: false)
                observations[share.recordID] = observed
                result[objectID] = observed
            }
        }
        return result
    }

    func canUpdate(_ id: NSManagedObjectID) -> Bool { (try? cloud().canUpdateRecord(forManagedObjectWith: id)) ?? false }

    func fetch(_ identity: HomeShareIdentity, scope: ActiveHomeScope, role: PersistenceStoreRole) async throws -> HomeBackendShare {
        let share: CKShare
        if role == .participantShared {
            guard let privateRecords, let provider = persistence.personalCartSessionProvider else { throw HomeMembershipError.shareUnavailable }
            let target = HomeNativeAccessIdentity(scope: HomeEffectScope(session: try provider.currentSession(),
                householdID: scope.graph.householdID, listID: scope.graph.listID),
                storeIdentifier: scope.graph.storeIdentifier, rootURI: scope.graph.rootURI,
                share: HomeEffectShare(recordName: identity.recordName, zoneName: identity.zoneName, zoneOwnerName: identity.zoneOwnerName))
            share = try await ManagedHomeAccessObserver(cart: privateRecords, persistence: persistence).verifiedShare(target)
        } else {
            let database = CKContainer(identifier: scope.containerIdentifier).privateCloudDatabase
            let id = CKRecord.ID(recordName: identity.recordName,
                zoneID: CKRecordZone.ID(zoneName: identity.zoneName, ownerName: identity.zoneOwnerName))
            guard let fetched = try await database.record(for: id) as? CKShare else { throw HomeMembershipError.shareUnavailable }
            share = fetched
        }
        return try Self.observation(share)
    }

    func create(store: NSPersistentStore, authorize: @escaping @Sendable () throws -> Void,
        prepareGraph: @escaping @Sendable (NSManagedObjectContext) throws -> HomeBackendCreation) async throws -> HomeBackendShare {
        let cloud = try cloud(), context = cloud.newBackgroundContext()
        let storeIdentifier = store.identifier
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    try authorize()
                    let prepared = try prepareGraph(context)
                    if let existing = prepared.existing {
                        continuation.resume(returning: existing)
                        return
                    }
                    let object = try context.existingObject(with: prepared.rootID)
                    guard let submissionStore = cloud.persistentStoreCoordinator.persistentStores.first(where: { $0.identifier == storeIdentifier }),
                          object.objectID.persistentStore === submissionStore else { throw HomeSharingError.ownerRequired }
                    try authorize()
                    // Graph validation, root resolution and SDK submission share this queue.
                    cloud.share([object], to: nil) { _, share, _, error in
                        if let error { continuation.resume(throwing: error); return }
                        do {
                            try authorize()
                            guard let share else { throw HomeSharingError.missingResult }
                            guard share.currentUserParticipant?.role == .owner else { throw HomeSharingError.ownerRequired }
                            guard share.publicPermission == .none else { throw HomeSharingError.unexpectedPublicAccess }
                            share.publicPermission = .none
                            share[CKShare.SystemFieldKey.title] = prepared.title as CKRecordValue
                            let identity = Self.identity(share)
                            cloud.persistUpdatedShare(share, in: submissionStore) { saved, error in
                                if let error { continuation.resume(throwing: error); return }
                                do {
                                    try authorize()
                                    guard let saved else { throw HomeSharingError.missingResult }
                                    guard Self.identity(saved) == identity else { throw HomeSharingError.conflictingShare }
                                    NotificationCenter.default.post(name: PersistenceController.pendingShareAssociation, object: self.persistence)
                                    continuation.resume(returning: try Self.observation(saved))
                                } catch { continuation.resume(throwing: error) }
                            }
                        } catch { continuation.resume(throwing: error) }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func save(_ share: HomeBackendShare, mutation: HomeBackendMutation, store: NSPersistentStore, authorize: @escaping @Sendable () throws -> Void) async throws -> HomeBackendShare {
        let native: CKShare
        do {
            try authorize()
            native = try restored(share)
            switch mutation {
            case .add(let material): native.addParticipant(try ManagedHomeMembershipTransport.restoredParticipant(material))
            case .remove(let ids):
                for participant in native.participants where ids.contains(participant.__participantID) {
                    native.removeParticipant(participant)
                }
            }
            try authorize()
        } catch { throw HomeMembershipNotSubmitted(reason: error) }
        return try Self.observation(await persist(native, store: store, authorize: authorize))
    }

    func invitationURL(_ share: HomeBackendShare, participantID: String) throws -> URL? {
        ShoppingOneTimeInvitationURL(try restored(share), participantID)
    }

    private func persist(_ share: CKShare, store: NSPersistentStore,
        authorize: @escaping @Sendable () throws -> Void) async throws -> CKShare {
        let cloud: NSPersistentCloudKitContainer
        do { cloud = try self.cloud() }
        catch { throw HomeMembershipNotSubmitted(reason: error) }
        return try await withCheckedThrowingContinuation { continuation in
            do { try authorize() }
            catch { continuation.resume(throwing: HomeMembershipNotSubmitted(reason: error)); return }
            cloud.persistUpdatedShare(share, in: store) { saved, error in
                if let error { continuation.resume(throwing: error) }
                else if let saved { continuation.resume(returning: saved) }
                else { continuation.resume(throwing: HomeMembershipError.outcomeUncertain) }
            }
        }
    }

    private func restored(_ value: HomeBackendShare) throws -> CKShare {
        guard let share = (value.backing as? Backing)?.share,
              Self.identity(share) == value.identity, share.recordChangeTag == value.changeTag else { throw HomeMembershipError.shareUnavailable }
        return share
    }

    private static func identity(_ share: CKShare) -> HomeShareIdentity {
        HomeShareIdentity(recordName: share.recordID.recordName, zoneName: share.recordID.zoneID.zoneName,
            zoneOwnerName: share.recordID.zoneID.ownerName)
    }

    private static func observation(_ share: CKShare, includeInvitationURLs: Bool = true) throws -> HomeBackendShare {
        let participants = share.participants.map { participant in
            let url: URL?
            if #available(iOS 18.0, *), includeInvitationURLs, share.currentUserParticipant?.role == .owner,
               participant.acceptanceStatus == .pending, participant.role == .privateUser, participant.permission == .readWrite {
                url = ShoppingOneTimeInvitationURL(share, participant.__participantID)
            } else { url = nil }
            return HomeBackendParticipant(id: participant.__participantID, role: participant.role,
                permission: participant.permission, acceptance: participant.acceptanceStatus,
                name: participant.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) },
                email: participant.userIdentity.lookupInfo?.emailAddress, hasInvitationURL: url != nil)
        }
        return HomeBackendShare(identity: identity(share), publicPermission: share.publicPermission,
            currentParticipantID: share.currentUserParticipant?.__participantID, participants: participants,
            changeTag: share.recordChangeTag,
            backing: Backing(share))
    }
}
