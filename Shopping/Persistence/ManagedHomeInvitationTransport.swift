import CloudKit
import CoreData

protocol HomeInvitationTransport: Sendable {
    func existingShare(identity: HomeShareIdentity) async throws -> Bool
    func accept(metadataArchive: Data, identity: HomeShareIdentity) async throws
    func importedHome(identity: HomeShareIdentity) async throws -> HomeGraphIdentity?
}

enum ManagedHomeInvitationError: Error, LocalizedError {
    case invalidMetadata, accountUnavailable, accountChanged, sharedStoreUnavailable
    case unsupportedAccess, ambiguousHome, missingAcceptanceResult

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "This invitation could not be opened. Open the original invitation again."
        case .accountUnavailable: return "Verify your iCloud account before joining this home."
        case .accountChanged: return "Your iCloud account changed. Reopen the invitation in its original account."
        case .sharedStoreUnavailable: return "Shared groceries are not ready. Try joining again after setup finishes."
        case .unsupportedAccess: return "This invitation has unsupported sharing permissions."
        case .ambiguousHome: return "The invited home is not uniquely identifiable yet. Your groceries are retained."
        case .missingAcceptanceResult: return "iCloud has not confirmed this invitation. Check again before retrying."
        }
    }
}

/// No selected-home authority is involved: accepting an invitation never activates its home.
/// Managed objects stay on context queues; the immutable session fences account-bound work.
final class ManagedHomeInvitationTransport: HomeInvitationTransport, @unchecked Sendable {
    private let persistence: PersistenceController
    private let session: ShopperSession

    init(persistence: PersistenceController, session: ShopperSession) {
        self.persistence = persistence
        self.session = session
    }

    static func archive(_ metadata: CKShare.Metadata) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: metadata, requiringSecureCoding: true)
    }

    static func identity(in archive: Data, session: ShopperSession) throws -> HomeShareIdentity {
        let metadata = try decode(archive)
        try validate(metadata, session: session)
        return identity(of: metadata.share)
    }

    func existingShare(identity: HomeShareIdentity) async throws -> Bool {
        try await withJoinGate(identity) { try await self.readExistingShare(identity: identity) }
    }

    private func readExistingShare(identity: HomeShareIdentity) async throws -> Bool {
        let (cloud, _) = try environment()
        let context = cloud.newBackgroundContext()
        return try await context.perform {
            let (cloud, store) = try self.environment()
            // The local share can exist before its household root has finished importing.
            let matches = try cloud.fetchShares(in: store).filter { Self.identity(of: $0) == identity }
            guard matches.count <= 1 else { throw ManagedHomeInvitationError.ambiguousHome }
            let accepted: Bool
            if let share = matches.first {
                try Self.validatePrivateShare(share)
                accepted = share.currentUserParticipant?.acceptanceStatus == .accepted
            } else { accepted = false }
            _ = try self.environment()
            return accepted
        }
    }

    func accept(metadataArchive: Data, identity: HomeShareIdentity) async throws {
        try await withJoinGate(identity) { try await self.acceptInvitation(metadataArchive: metadataArchive, identity: identity) }
    }

    private func acceptInvitation(metadataArchive: Data, identity: HomeShareIdentity) async throws {
        let metadata = try Self.decode(metadataArchive)
        try Self.validate(metadata, session: session)
        guard Self.identity(of: metadata.share) == identity else {
            throw ManagedHomeInvitationError.invalidMetadata
        }
        let (cloud, store) = try environment()
        // Keep the continuation alive until the native callback. Cancellation is not
        // evidence that CloudKit cancelled an in-flight acceptance.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                _ = try environment()
                cloud.acceptShareInvitations(from: [metadata], into: store) { accepted, error in
                    do {
                        _ = try self.environment()
                        if let error { throw error }
                        guard let accepted, accepted.count == 1, let result = accepted.first else {
                            throw ManagedHomeInvitationError.missingAcceptanceResult
                        }
                        try Self.validate(result, session: self.session)
                        guard Self.identity(of: result.share) == identity else {
                            throw ManagedHomeInvitationError.missingAcceptanceResult
                        }
                        // The callback confirms the operation, not fresh participant
                        // metadata or graph import. Imported share metadata must establish
                        // accepted membership before importedHome returns a usable home.
                        _ = try self.environment()
                        continuation.resume(returning: ())
                    } catch { continuation.resume(throwing: error) }
                }
            } catch { continuation.resume(throwing: error) }
        }
    }

    func importedHome(identity: HomeShareIdentity) async throws -> HomeGraphIdentity? {
        try await withJoinGate(identity) { try await self.readImportedHome(identity: identity) }
    }

    private func readImportedHome(identity: HomeShareIdentity) async throws -> HomeGraphIdentity? {
        let (cloud, _) = try environment()
        // This synchronous reader confines its work to the serial writer. This async
        // non-main-actor transport is called off the UI actor, as are native share lookups.
        let discovery = try HomeDiscoveryService(persistence: persistence).discover()
        _ = try environment()
        let context = cloud.newBackgroundContext()
        return try await context.perform {
            let (cloud, store) = try self.environment()
            let request = Household.fetchRequest()
            request.affectedStores = [store]
            let roots = try context.fetch(request)
            let shares = try cloud.fetchShares(matching: roots.map(\.objectID))
            let matchingRoots = roots.filter { root in
                shares[root.objectID].map { Self.identity(of: $0) == identity } ?? false
            }
            guard matchingRoots.count <= 1 else { throw ManagedHomeInvitationError.ambiguousHome }
            guard let root = matchingRoots.first, let share = shares[root.objectID] else {
                _ = try self.environment()
                return nil
            }
            try Self.validateAcceptedShare(share)
            let candidates = discovery.homes.filter {
                $0.graph.storeIdentifier == store.identifier
                    && $0.graph.rootURI == root.objectID.uriRepresentation().absoluteString
            }
            guard candidates.count <= 1 else { throw ManagedHomeInvitationError.ambiguousHome }
            // Structural readiness must remain reachable for explicit rejoin.
            // Discovery's blocked write authority is not an incomplete graph.
            guard let candidate = candidates.first,
                  root.id == candidate.graph.householdID,
                  let list = root.groceryList, list.household == root,
                  list.id == candidate.graph.listID, list.objectID.persistentStore === store else {
                _ = try self.environment()
                return nil
            }
            // Recheck identities after discovery: an import may have arrived between contexts.
            let rootIDs = Household.fetchRequest()
            rootIDs.predicate = NSPredicate(format: "id == %@", candidate.graph.householdID as CVarArg)
            let listIDs = GroceryList.fetchRequest()
            listIDs.predicate = NSPredicate(format: "id == %@", candidate.graph.listID as CVarArg)
            guard try context.count(for: rootIDs) == 1, try context.count(for: listIDs) == 1 else {
                throw ManagedHomeInvitationError.ambiguousHome
            }
            guard let listShare = try cloud.fetchShares(matching: [list.objectID])[list.objectID] else {
                _ = try self.environment()
                return nil
            }
            guard Self.identity(of: listShare) == identity else {
                throw ManagedHomeInvitationError.ambiguousHome
            }
            _ = try self.environment()
            // No need-count condition: a complete imported home may have no groceries.
            return candidate.graph
        }
    }

    private func withJoinGate<Value: Sendable>(_ identity: HomeShareIdentity,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        let share = HomeEffectShare(recordName: identity.recordName, zoneName: identity.zoneName, zoneOwnerName: identity.zoneOwnerName)
        return try await persistence.homeParticipantOperations.perform(in: HomeParticipantZone(session: session, share: share)) {
            _ = try self.environment()
            try await HomeJoinGate.validate(persistence: self.persistence, session: self.session, share: share)
            _ = try self.environment()
            let result = try await operation()
            try await HomeJoinGate.validate(persistence: self.persistence, session: self.session, share: share)
            _ = try self.environment()
            return result
        }
    }

    /// Resolve one selected graph to its actual share, rather than treating every home
    /// in the participant store as belonging to the same outstanding invitation.
    func shareIdentity(for graph: HomeGraphIdentity) async throws -> HomeShareIdentity? {
        let (cloud, _) = try environment(allowCachedLookup: true)
        let context = cloud.newBackgroundContext()
        return try await context.perform {
            let (cloud, store) = try self.environment(allowCachedLookup: true)
            guard graph.storeIdentifier == store.identifier,
                  let uri = URL(string: graph.rootURI),
                  let objectID = cloud.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri),
                  objectID.persistentStore === store,
                  let root = try context.existingObject(with: objectID) as? Household,
                  root.id == graph.householdID,
                  let list = root.groceryList, list.id == graph.listID,
                  list.household == root, list.objectID.persistentStore === store else {
                throw ManagedHomeInvitationError.ambiguousHome
            }
            let shares = try cloud.fetchShares(matching: [root.objectID, list.objectID])
            guard let rootShare = shares[root.objectID], let listShare = shares[list.objectID] else {
                _ = try self.environment(allowCachedLookup: true)
                return nil
            }
            try Self.validateAcceptedShare(rootShare)
            try Self.validateAcceptedShare(listShare)
            let identity = Self.identity(of: rootShare)
            guard identity == Self.identity(of: listShare) else { throw ManagedHomeInvitationError.ambiguousHome }
            _ = try self.environment(allowCachedLookup: true)
            return identity
        }
    }

    private func environment(allowCachedLookup: Bool = false) throws -> (NSPersistentCloudKitContainer, NSPersistentStore) {
        guard let provider = persistence.personalCartSessionProvider as? ShopperSessionProvider else {
            throw ManagedHomeInvitationError.accountUnavailable
        }
        let verified: ShopperSession
        switch provider.state {
        case .ready(let current): verified = current
        case .cached(let current) where allowCachedLookup: verified = current
        default: throw ManagedHomeInvitationError.accountUnavailable
        }
        // Only read-only local share mapping can use cached authority. Accept/import
        // retain their verified-online gate; an invalidated binding is never usable.
        guard verified == session, try provider.currentSession() == session,
              persistence.personalCartInitialBinding == session.accountBinding else {
            throw ManagedHomeInvitationError.accountChanged
        }
        guard case .managed(let privateURL, let sharedURL, let containerID) = persistence.configuration,
              containerID == session.containerIdentifier,
              privateURL.deletingLastPathComponent().lastPathComponent == session.accountBinding,
              sharedURL.deletingLastPathComponent().lastPathComponent == session.accountBinding,
              let cloud = persistence.container as? NSPersistentCloudKitContainer,
              let store = persistence.store(for: .participantShared), store.url == sharedURL,
              cloud.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              let description = cloud.persistentStoreDescriptions.first(where: { $0.url == sharedURL }),
              description.cloudKitContainerOptions?.databaseScope == .shared,
              description.cloudKitContainerOptions?.containerIdentifier == session.containerIdentifier else {
            throw ManagedHomeInvitationError.sharedStoreUnavailable
        }
        return (cloud, store)
    }

    private static func decode(_ archive: Data) throws -> CKShare.Metadata {
        do {
            guard let metadata = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKShare.Metadata.self, from: archive) else {
                throw ManagedHomeInvitationError.invalidMetadata
            }
            return metadata
        } catch { throw ManagedHomeInvitationError.invalidMetadata }
    }

    private static func validate(_ metadata: CKShare.Metadata, session: ShopperSession) throws {
        // Metadata exposes a container identifier, not a CloudKit environment. Environment
        // isolation comes from the verified session and its configured account store.
        guard session.isWellFormed, metadata.containerIdentifier == session.containerIdentifier else {
            throw ManagedHomeInvitationError.invalidMetadata
        }
        guard metadata.share.publicPermission == .none, metadata.participantRole == .privateUser,
              metadata.participantPermission == .readWrite || metadata.participantPermission == .readOnly,
              metadata.participantStatus == .pending || metadata.participantStatus == .accepted else {
            throw ManagedHomeInvitationError.unsupportedAccess
        }
    }

    private static func validateAcceptedShare(_ share: CKShare) throws {
        try validatePrivateShare(share)
        guard share.currentUserParticipant?.acceptanceStatus == .accepted else {
            throw ManagedHomeInvitationError.missingAcceptanceResult
        }
    }

    private static func validatePrivateShare(_ share: CKShare) throws {
        guard share.publicPermission == .none, let participant = share.currentUserParticipant,
              participant.role == .privateUser,
              participant.acceptanceStatus == .pending || participant.acceptanceStatus == .accepted,
              participant.permission == .readWrite || participant.permission == .readOnly else {
            throw ManagedHomeInvitationError.unsupportedAccess
        }
    }

    private static func identity(of share: CKShare) -> HomeShareIdentity {
        HomeShareIdentity(recordName: share.recordID.recordName,
            zoneName: share.recordID.zoneID.zoneName, zoneOwnerName: share.recordID.zoneID.ownerName)
    }
}
