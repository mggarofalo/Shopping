import CloudKit
import CoreData
import Foundation

/// Reads only the known managed share through CloudKit. All membership writes use
/// Core Data's managed share API; domain records never go through raw CloudKit APIs.
final class ManagedHomeMembershipTransport: HomeMembershipTransport, @unchecked Sendable {
    private struct Graph: Sendable {
        let name: String
        let share: HomeShareIdentity?
        let canEdit: Bool
    }
    private let persistence: PersistenceController
    private let authority: UICommandAuthority
    private let privateRecords: PersonalCartService?

    init(persistence: PersistenceController, authority: UICommandAuthority, privateRecords: PersonalCartService?) {
        self.persistence = persistence
        self.authority = authority
        self.privateRecords = privateRecords
    }

    func refresh(scope: ActiveHomeScope) async throws -> HomeMembershipSnapshot {
        let (cloud, store, role) = try environment(scope)
        let graph = try await graph(scope, cloud: cloud, store: store)
        guard let identity = graph.share else {
            guard role == .ownerPrivate else { throw HomeMembershipError.shareUnavailable }
            _ = try environment(scope)
            return HomeMembershipSnapshot(scope: scope, share: nil, homeName: graph.name,
                access: graph.canEdit ? .owner : .restricted, currentParticipantID: nil,
                members: [], changeTag: nil, observedAt: Date(), source: .localUnshared)
        }
        let share = try await fetch(identity, scope: scope, role: role)
        return try snapshot(share, scope: scope, graph: graph, role: role)
    }

    func makeInvitationParticipant(scope: ActiveHomeScope) async throws -> HomeInviteMaterial {
        guard #available(iOS 18.0, *) else { throw HomeMembershipError.unsupportedVersion }
        let current = try await refresh(scope: scope)
        try requireOwner(current)
        return try Self.makeParticipantMaterial()
    }

    @available(iOS 18.0, *)
    static func makeParticipantMaterial() throws -> HomeInviteMaterial {
        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = .readWrite
        participant.role = .privateUser
        let id = participant.__participantID
        guard !id.isEmpty else { throw HomeMembershipError.invalidParticipant }
        let archive = try NSKeyedArchiver.archivedData(withRootObject: participant, requiringSecureCoding: true)
        let material = HomeInviteMaterial(participantID: id, archive: archive)
        _ = try restoredParticipant(material)
        return material
    }

    static func restoredParticipant(_ material: HomeInviteMaterial) throws -> CKShare.Participant {
        guard !material.participantID.isEmpty,
              let participant = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKShare.Participant.self, from: material.archive),
              participant.__participantID == material.participantID,
              participant.role == .privateUser, participant.permission == .readWrite,
              participant.acceptanceStatus == .pending,
              participant.userIdentity.lookupInfo == nil else { throw HomeMembershipError.invalidParticipant }
        return participant
    }

    func addInvitation(_ material: HomeInviteMaterial, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot {
        let scope = expected.scope
        let cloud: NSPersistentCloudKitContainer
        let store: NSPersistentStore
        let share: CKShare
        let graph: Graph
        // Only failures in this block are proof that no native write was submitted.
        do {
            guard #available(iOS 18.0, *) else { throw HomeMembershipError.unsupportedVersion }
            let (currentCloud, currentStore, role) = try environment(scope)
            guard role == .ownerPrivate, let identity = expected.share else { throw HomeMembershipError.ownerRequired }
            cloud = currentCloud; store = currentStore
            graph = try await self.graph(scope, cloud: cloud, store: store)
            guard graph.share == identity else { throw HomeMembershipError.scopeChanged }
            share = try await fetch(identity, scope: scope, role: role)
            let fresh = try snapshot(share, scope: scope, graph: graph, role: role)
            try requireOwner(fresh)
            guard fresh.changeTag == expected.changeTag, fresh.members == expected.members else {
                throw HomeMembershipError.membershipChanged
            }
            guard !share.participants.contains(where: { $0.__participantID == material.participantID }) else {
                throw HomeMembershipError.membershipChanged
            }
            let removals = try await retainedRemovals(scope: scope, share: identity)
            guard !removals.contains(where: { $0.participantIDs.contains(material.participantID) }) else {
                throw HomeMembershipError.invitationCancelled
            }
            let participant = try Self.restoredParticipant(material)
            share.addParticipant(participant)
            // Never change publicPermission as a shortcut: doing so may remove participants.
            guard share.publicPermission == .none else { throw HomeMembershipError.unsupportedAccess }
            _ = try environment(scope)
        } catch {
            throw HomeMembershipNotSubmitted(reason: error as? HomeMembershipError ?? .shareUnavailable)
        }
        let saved: CKShare = try await withCheckedThrowingContinuation { continuation in
            cloud.persistUpdatedShare(share, in: store) { saved, error in
                if let error { continuation.resume(throwing: error) }
                else if let saved { continuation.resume(returning: saved) }
                else { continuation.resume(throwing: HomeMembershipError.outcomeUncertain) }
            }
        }
        _ = try environment(scope)
        guard Self.identity(saved) == expected.share else { throw HomeMembershipError.scopeChanged }
        let result = try snapshot(saved, scope: scope, graph: graph, role: .ownerPrivate)
        try requireOwner(result)
        guard result.members.contains(where: { $0.id == material.participantID && $0.role == .contributor }) else {
            throw HomeMembershipError.outcomeUncertain
        }
        return result
    }

    func invitationURL(participantID: String, scope: ActiveHomeScope, share identity: HomeShareIdentity) async throws -> URL {
        guard #available(iOS 18.0, *) else { throw HomeMembershipError.unsupportedVersion }
        let (cloud, store, role) = try environment(scope)
        guard role == .ownerPrivate else { throw HomeMembershipError.ownerRequired }
        let graph = try await graph(scope, cloud: cloud, store: store)
        guard graph.share == identity else { throw HomeMembershipError.scopeChanged }
        let share = try await fetch(identity, scope: scope, role: role)
        let fresh = try snapshot(share, scope: scope, graph: graph, role: role)
        try requireOwner(fresh)
        guard let participant = share.participants.first(where: { $0.__participantID == participantID }) else {
            throw HomeMembershipError.invitationUnavailable
        }
        guard participant.acceptanceStatus != .accepted else { throw HomeMembershipError.invitationAlreadyAccepted }
        guard participant.role == .privateUser, participant.permission == .readWrite,
              participant.acceptanceStatus == .pending else { throw HomeMembershipError.invalidParticipant }
        guard let url = share.__oneTimeURL(forParticipantID: participantID) else { throw HomeMembershipError.missingURL }
        let removals = try await retainedRemovals(scope: scope, share: identity)
        guard !removals.contains(where: { $0.participantIDs.contains(participantID) }) else { throw HomeMembershipError.invitationCancelled }
        _ = try environment(scope)
        return url
    }

    func retainedRemovals(scope: ActiveHomeScope, share: HomeShareIdentity) async throws -> [HomeMembershipRemoval] {
        let (_, _, role) = try environment(scope)
        guard role == .ownerPrivate else { return [] }
        guard let privateRecords else { throw HomeMembershipError.shareUnavailable }
        let result = try await Task.detached(priority: .utility) {
            try privateRecords.retainedHomeMemberRemovals(scope: scope, share: share)
        }.value
        _ = try environment(scope)
        return result
    }

    func retainRemoval(_ removal: HomeMembershipRemoval, scope: ActiveHomeScope) async throws {
        let (cloud, store, role) = try environment(scope)
        guard role == .ownerPrivate, let privateRecords,
              removal.matches(scope: scope, share: removal.share) else { throw HomeMembershipError.ownerRequired }
        let graph = try await graph(scope, cloud: cloud, store: store)
        guard graph.share == removal.share else { throw HomeMembershipError.scopeChanged }
        try await Task.detached(priority: .userInitiated) { try privateRecords.retainHomeMemberRemoval(removal) }.value
        _ = try environment(scope)
    }

    func removeParticipants(_ participantIDs: Set<String>, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot {
        let scope = expected.scope
        let cloud: NSPersistentCloudKitContainer
        let store: NSPersistentStore
        let graph: Graph
        let share: CKShare
        do {
            let (currentCloud, currentStore, role) = try environment(scope)
            guard role == .ownerPrivate, let identity = expected.share else { throw HomeMembershipError.ownerRequired }
            cloud = currentCloud; store = currentStore
            graph = try await self.graph(scope, cloud: cloud, store: store)
            guard graph.share == identity else { throw HomeMembershipError.scopeChanged }
            share = try await fetch(identity, scope: scope, role: role)
            let fresh = try snapshot(share, scope: scope, graph: graph, role: role)
            try requireOwner(fresh)
            guard !participantIDs.isEmpty, !participantIDs.contains(fresh.currentParticipantID!),
                  !share.participants.contains(where: { participantIDs.contains($0.__participantID) && $0.role == .owner }) else {
                throw HomeMembershipError.invalidParticipant
            }
            guard fresh.changeTag == expected.changeTag, fresh.members == expected.members else { throw HomeMembershipError.membershipChanged }
            let authorizations = try await retainedRemovals(scope: scope, share: identity)
            let authorized = authorizations.reduce(into: Set<String>()) { $0.formUnion($1.participantIDs) }
            guard participantIDs.isSubset(of: authorized) else { throw HomeMembershipError.invalidParticipant }
            let targets = share.participants.filter { participantIDs.contains($0.__participantID) }
            guard !targets.isEmpty else { return fresh }
            for target in targets { share.removeParticipant(target) }
            _ = try environment(scope)
        } catch {
            throw HomeMembershipNotSubmitted(reason: error as? HomeMembershipError ?? .shareUnavailable)
        }
        let saved: CKShare = try await withCheckedThrowingContinuation { continuation in
            cloud.persistUpdatedShare(share, in: store) { saved, error in
                if let error { continuation.resume(throwing: error) }
                else if let saved { continuation.resume(returning: saved) }
                else { continuation.resume(throwing: HomeMembershipError.outcomeUncertain) }
            }
        }
        _ = try environment(scope)
        guard Self.identity(saved) == expected.share else { throw HomeMembershipError.scopeChanged }
        // Callback confirms this managed export; a new server read confirms current
        // membership. Neither claim implies that offline peers erased their caches.
        let observed = try await fetch(Self.identity(saved), scope: scope, role: .ownerPrivate)
        let result = try snapshot(observed, scope: scope, graph: graph, role: .ownerPrivate)
        try requireOwner(result)
        return result
    }

    private func environment(_ scope: ActiveHomeScope) throws -> (NSPersistentCloudKitContainer, NSPersistentStore, PersistenceStoreRole) {
        try authority.validate()
        guard let provider = persistence.personalCartSessionProvider as? ShopperSessionProvider,
              case .ready(let session) = provider.state,
              try provider.currentSession() == session,
              session.accountBinding == scope.accountBinding,
              session.containerIdentifier == scope.containerIdentifier,
              session.environment == scope.environment,
              persistence.personalCartInitialBinding == scope.accountBinding else { throw HomeMembershipError.scopeChanged }
        guard case .managed(let privateURL, let sharedURL, let containerID) = persistence.configuration,
              containerID == scope.containerIdentifier,
              let cloud = persistence.container as? NSPersistentCloudKitContainer,
              let binding = persistence.storeBindings.first(where: { $0.store.identifier == scope.graph.storeIdentifier }),
              binding.role == .ownerPrivate || binding.role == .participantShared,
              cloud.persistentStoreCoordinator.persistentStores.contains(where: { $0 === binding.store }) else {
            throw HomeMembershipError.shareUnavailable
        }
        let url = binding.role == .ownerPrivate ? privateURL : sharedURL
        guard binding.store.url == url, url.deletingLastPathComponent().lastPathComponent == scope.accountBinding,
              let description = cloud.persistentStoreDescriptions.first(where: { $0.url == url }),
              description.cloudKitContainerOptions?.containerIdentifier == containerID,
              description.cloudKitContainerOptions?.databaseScope == (binding.role == .ownerPrivate ? .private : .shared) else {
            throw HomeMembershipError.scopeChanged
        }
        return (cloud, binding.store, binding.role)
    }

    private func graph(_ scope: ActiveHomeScope, cloud: NSPersistentCloudKitContainer, store: NSPersistentStore) async throws -> Graph {
        let context = cloud.newBackgroundContext()
        return try await context.perform {
            _ = try self.environment(scope)
            guard let uri = URL(string: scope.graph.rootURI),
                  let id = cloud.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri),
                  id.persistentStore === store,
                  let root = try context.existingObject(with: id) as? Household,
                  root.id == scope.graph.householdID,
                  let list = root.groceryList, list.id == scope.graph.listID,
                  list.household == root, list.objectID.persistentStore === store else { throw HomeMembershipError.scopeChanged }
            let roots = Household.fetchRequest(); roots.predicate = NSPredicate(format: "id == %@", root.id as CVarArg)
            let lists = GroceryList.fetchRequest(); lists.predicate = NSPredicate(format: "id == %@", list.id as CVarArg)
            guard try context.count(for: roots) == 1, try context.count(for: lists) == 1 else { throw HomeMembershipError.scopeChanged }
            let shares = try cloud.fetchShares(matching: [root.objectID, list.objectID])
            let rootShare = shares[root.objectID], listShare = shares[list.objectID]
            guard rootShare.map(Self.identity) == listShare.map(Self.identity) else { throw HomeMembershipError.shareUnavailable }
            _ = try self.environment(scope)
            return Graph(name: root.name, share: rootShare.map(Self.identity),
                canEdit: cloud.canUpdateRecord(forManagedObjectWith: root.objectID))
        }
    }

    private func fetch(_ identity: HomeShareIdentity, scope: ActiveHomeScope, role: PersistenceStoreRole) async throws -> CKShare {
        _ = try environment(scope)
        let container = CKContainer(identifier: scope.containerIdentifier)
        let database = role == .ownerPrivate ? container.privateCloudDatabase : container.sharedCloudDatabase
        let id = CKRecord.ID(recordName: identity.recordName,
            zoneID: CKRecordZone.ID(zoneName: identity.zoneName, ownerName: identity.zoneOwnerName))
        let record = try await database.record(for: id)
        _ = try environment(scope)
        guard let share = record as? CKShare, Self.identity(share) == identity else { throw HomeMembershipError.shareUnavailable }
        return share
    }

    private func snapshot(_ share: CKShare, scope: ActiveHomeScope, graph: Graph,
                          role: PersistenceStoreRole) throws -> HomeMembershipSnapshot {
        guard share.publicPermission == .none, let current = share.currentUserParticipant,
              current.acceptanceStatus == .accepted,
              current.role == .owner || current.role == .privateUser,
              current.permission == .readWrite || current.permission == .readOnly,
              (current.role == .owner) == (role == .ownerPrivate) else { throw HomeMembershipError.unsupportedAccess }
        let ids = share.participants.map(\.__participantID)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
              share.participants.filter({ $0.role == .owner }).count == 1,
              ids.contains(current.__participantID) else { throw HomeMembershipError.invalidParticipant }
        let access: HomeMembershipSnapshot.Access
        if current.role == .owner {
            guard current.permission == .readWrite, graph.canEdit else { throw HomeMembershipError.unsupportedAccess }
            access = .owner
        } else { access = current.permission == .readWrite && graph.canEdit ? .contributor : .restricted }
        let members = try share.participants.filter { $0.acceptanceStatus != .removed }.map { participant -> HomeMember in
            guard participant.role == .owner || participant.role == .privateUser else { throw HomeMembershipError.unsupportedAccess }
            let status: HomeMember.Acceptance
            switch participant.acceptanceStatus {
            case .accepted: status = .accepted
            case .pending: status = .pending
            default: status = .unknown
            }
            let role: HomeMember.Role = participant.role == .owner ? .owner
                : (participant.permission == .readWrite ? .contributor : .restricted)
            let name = participant.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            let canResend: Bool
            if #available(iOS 18.0, *) {
                canResend = access == .owner && status == .pending && role == .contributor
                    && share.__oneTimeURL(forParticipantID: participant.__participantID) != nil
            } else { canResend = false }
            return HomeMember(id: participant.__participantID, name: name, role: role,
                acceptance: status, isCurrentUser: participant.__participantID == current.__participantID, canResend: canResend)
        }.sorted { $0.id < $1.id }
        return HomeMembershipSnapshot(scope: scope, share: Self.identity(share), homeName: graph.name, access: access,
            currentParticipantID: current.__participantID, members: members, changeTag: share.recordChangeTag,
            observedAt: Date(), source: .server)
    }

    private func requireOwner(_ snapshot: HomeMembershipSnapshot) throws {
        guard snapshot.access == .owner, snapshot.source == .server, snapshot.share != nil,
              snapshot.members.contains(where: { $0.isCurrentUser && $0.role == .owner && $0.acceptance == .accepted }) else {
            throw HomeMembershipError.ownerRequired
        }
    }

    private static func identity(_ share: CKShare) -> HomeShareIdentity {
        HomeShareIdentity(recordName: share.recordID.recordName,
            zoneName: share.recordID.zoneID.zoneName, zoneOwnerName: share.recordID.zoneID.ownerName)
    }
}
