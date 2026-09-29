import CloudKit
import CoreData
import Foundation

final class CloudKitHomeLeaveBackend: HomeLeaveBackend, @unchecked Sendable {
    private let cart: PersonalCartService
    private let persistence: PersistenceController

    init(cart: PersonalCartService, persistence: PersistenceController) {
        self.cart = cart
        self.persistence = persistence
    }

    func validateEnvironment(identity: HomeNativeAccessIdentity, storeURL: URL?) throws -> ShopperSession {
        try environment(identity, storeURL: storeURL).session
    }

    func validateMapping(identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws {
        guard repository.persistence === persistence else { throw PersonalCartError.scopeChanged }
        let target = try environment(identity)
        guard repository.session == target.session else { throw PersonalCartError.accountChanged }
        let home = try repository.household(identity.scope.householdID)
        guard try repository.nativeAccessIdentity(for: home) == identity else { throw PersonalCartError.scopeChanged }
        let zone = Self.zone(identity.share)
        let shares = try target.cloud.fetchShares(in: target.store)
        guard !shares.contains(where: { $0.recordID.zoneID == zone && $0.recordID.recordName != identity.share.recordName }) else {
            throw ManagedHomeLeaveTransport.Failure.sharedZone
        }
        let homesRequest = Household.fetchRequest()
        homesRequest.affectedStores = [target.store]
        let homes = try repository.context.fetch(homesRequest)
        let listsRequest = GroceryList.fetchRequest()
        listsRequest.affectedStores = [target.store]
        let lists = try repository.context.fetch(listsRequest)
        let mapped = try target.cloud.fetchShares(matching: homes.map(\.objectID) + lists.map(\.objectID))
        let objects: [NSManagedObject] = homes + lists
        for object in objects {
            guard let share = mapped[object.objectID] else { throw ManagedHomeLeaveTransport.Failure.sharedZone }
            if share.recordID.zoneID == zone,
               object.objectID != home.objectID && object.objectID != home.groceryList?.objectID {
                throw ManagedHomeLeaveTransport.Failure.sharedZone
            }
        }
        guard try environment(identity).store === target.store else { throw PersonalCartError.scopeChanged }
    }

    func membership(identity: HomeNativeAccessIdentity) async throws -> HomeLeaveMembership {
        let target = try environment(identity)
        let id = CKRecord.ID(recordName: identity.share.recordName, zoneID: Self.zone(identity.share))
        let record = try await CKContainer(identifier: identity.scope.containerIdentifier).sharedCloudDatabase.record(for: id)
        guard try environment(identity).store === target.store else { throw PersonalCartError.scopeChanged }
        guard let share = record as? CKShare, share.recordID == id else { throw PersonalCartError.scopeChanged }
        let participant = share.currentUserParticipant.map { participant in
            HomeLeaveMembership.Participant(id: participant.__participantID,
                role: participant.role == .owner ? .owner : participant.role == .privateUser ? .privateUser : .other,
                acceptance: participant.acceptanceStatus == .accepted ? .accepted : participant.acceptanceStatus == .pending ? .pending : .other,
                permission: participant.permission == .readOnly ? .readOnly : participant.permission == .readWrite ? .readWrite : .other)
        }
        return HomeLeaveMembership(share: HomeEffectShare(recordName: share.recordID.recordName,
            zoneName: share.recordID.zoneID.zoneName, zoneOwnerName: share.recordID.zoneID.ownerName),
            isPrivateShare: share.publicPermission == .none, currentParticipant: participant,
            privateParticipantIDs: Set(share.participants.filter { $0.role == .privateUser }.map(\.__participantID)))
    }

    func purge(_ command: HomeLeaveCommand, storeIdentity: ObjectIdentifier) async throws -> HomeLeaveZone {
        let target = try environment(command.origin, storeURL: command.storeURL)
        guard ObjectIdentifier(target.store) == storeIdentity else { throw PersonalCartError.scopeChanged }
        let zone = Self.zone(command.origin.share)
        let returned: CKRecordZone.ID = try await withCheckedThrowingContinuation { continuation in
            // A nonnil captured store prevents purging other active databases.
            target.cloud.purgeObjectsAndRecordsInZone(with: zone, in: target.store) { returned, error in
                if let error { continuation.resume(throwing: error) }
                else if let returned { continuation.resume(returning: returned) }
                else { continuation.resume(throwing: ManagedHomeLeaveTransport.Failure.outcomeUncertain) }
            }
        }
        guard try environment(command.origin, storeURL: command.storeURL).store === target.store else {
            throw PersonalCartError.scopeChanged
        }
        return HomeLeaveZone(name: returned.zoneName, ownerName: returned.ownerName)
    }

    func zoneExists(_ command: HomeLeaveCommand) async throws -> Bool {
        let target = try environment(command.origin, storeURL: command.storeURL)
        let zone = Self.zone(command.origin.share)
        let exists: Bool
        do {
            let result = try await CKContainer(identifier: command.origin.scope.containerIdentifier)
                .sharedCloudDatabase.recordZone(for: zone)
            guard result.zoneID == zone else { throw PersonalCartError.scopeChanged }
            exists = true
        } catch let error as CKError where error.code == .zoneNotFound {
            // Missing records and permission failures do not prove zone removal.
            exists = false
        }
        guard try environment(command.origin, storeURL: command.storeURL).store === target.store else {
            throw PersonalCartError.scopeChanged
        }
        return exists
    }

    private func environment(_ identity: HomeNativeAccessIdentity, storeURL: URL? = nil) throws
        -> (session: ShopperSession, cloud: NSPersistentCloudKitContainer, store: NSPersistentStore) {
        guard cart.persistence === persistence,
              let provider = cart.sessionProvider as? ShopperSessionProvider,
              case .ready(let session) = provider.state, try provider.currentSession() == session,
              let installed = persistence.personalCartSessionProvider as? ShopperSessionProvider, installed === provider,
              cart.initialAccountBinding == session.accountBinding,
              persistence.personalCartInitialBinding == session.accountBinding else { throw PersonalCartError.accountChanged }
        guard identity.scope == HomeEffectScope(session: session, householdID: identity.scope.householdID, listID: identity.scope.listID),
              case .managed(let privateURL, let sharedURL, let containerID) = persistence.configuration,
              containerID == session.containerIdentifier,
              privateURL.deletingLastPathComponent().lastPathComponent == session.accountBinding,
              sharedURL.deletingLastPathComponent().lastPathComponent == session.accountBinding,
              let cloud = persistence.container as? NSPersistentCloudKitContainer,
              let store = persistence.store(for: .participantShared), store.identifier == identity.storeIdentifier,
              store.url == sharedURL, storeURL == nil || storeURL?.standardizedFileURL == sharedURL.standardizedFileURL,
              cloud.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              let description = cloud.persistentStoreDescriptions.first(where: { $0.url == sharedURL }),
              description.cloudKitContainerOptions?.databaseScope == .shared,
              description.cloudKitContainerOptions?.containerIdentifier == containerID else { throw PersonalCartError.scopeChanged }
        return (session, cloud, store)
    }

    private static func zone(_ share: HomeEffectShare) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: share.zoneName, ownerName: share.zoneOwnerName)
    }
}
