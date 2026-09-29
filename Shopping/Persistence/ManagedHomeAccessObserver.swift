import CloudKit
import CoreData
import Foundation

/// Refreshes account-wide participant access, independently of the selected screen.
/// Only known managed CKShare records are read; domain data stays in Core Data.
final class ManagedHomeAccessObserver: @unchecked Sendable {
    struct Observation: Sendable {
        let id = UUID()
        let access: HomeNativeAccessGate.Access
        let changeTag: String?
    }
    private struct Pending: Sendable {
        let request: HomeNativeAccessGate.Request
        let restrictionIDs: Set<UUID>
    }
    private let cart: PersonalCartService
    private let persistence: PersistenceController

    init(cart: PersonalCartService, persistence: PersistenceController) {
        self.cart = cart
        self.persistence = persistence
    }

    /// A failure withholds publication, without inventing a durable loss event.
    func refresh() async -> String? {
        guard persistence.configuration.isManaged else { return nil }
        persistence.homeNativeAccess.invalidateVerification()
        do {
            let pending = try await Task.detached(priority: .utility) { try self.capture() }.value
            var firstFailure: String?
            for item in pending {
                do {
                    let (observation, _) = try await fetch(item.request.identity)
                    try await Task.detached(priority: .utility) { try self.apply(observation, to: item) }.value
                } catch {
                    if persistence.homeNativeAccess.isCurrent(item.request), firstFailure == nil {
                        firstFailure = error.localizedDescription
                    }
                }
            }
            return firstFailure
        } catch { return error.localizedDescription }
    }

    /// The members screen uses the same observation path as background replay.
    func verifiedShare(_ identity: HomeNativeAccessIdentity) async throws -> CKShare {
        let pending = try await Task.detached(priority: .utility) {
            try self.cart.transact(save: false) { repository in
                try self.validateEnvironment(identity)
                let home = try repository.household(identity.scope.householdID)
                guard try repository.nativeAccessIdentity(for: home) == identity else { throw PersonalCartError.scopeChanged }
                let access = try repository.homeEffectAccess(householdID: identity.scope.householdID, listID: identity.scope.listID)
                return Pending(request: self.persistence.homeNativeAccess.begin(identity), restrictionIDs: access.restrictionIDs)
            }
        }.value
        let (observation, share) = try await fetch(identity)
        try await Task.detached(priority: .utility) { try self.apply(observation, to: pending) }.value
        guard observation.access != .lost, let share else { throw PersonalCartError.unavailable }
        return share
    }

    private func capture() throws -> [Pending] {
        try cart.transact(save: false) { repository in
            try validateSession(repository.session)
            let homes = try repository.context.fetch(Household.fetchRequest())
            let counts = Dictionary(grouping: homes, by: \.id)
            var pending: [Pending] = []
            for home in homes {
                guard let store = home.objectID.persistentStore,
                      persistence.role(of: store) == .participantShared else { continue }
                // Partial roots are retained. Their missing verification denies publication.
                guard counts[home.id]?.count == 1, home.id != PersistenceModel.unsetID,
                      let identity = try? repository.nativeAccessIdentity(for: home) else { continue }
                try validateEnvironment(identity)
                let access = try repository.homeEffectAccess(householdID: identity.scope.householdID,
                    listID: identity.scope.listID)
                pending.append(Pending(request: persistence.homeNativeAccess.begin(identity),
                    restrictionIDs: access.restrictionIDs))
            }
            return pending
        }
    }

    private func fetch(_ identity: HomeNativeAccessIdentity) async throws -> (Observation, CKShare?) {
        try validateEnvironment(identity)
        let database = CKContainer(identifier: identity.scope.containerIdentifier).sharedCloudDatabase
        let id = CKRecord.ID(recordName: identity.share.recordName,
            zoneID: CKRecordZone.ID(zoneName: identity.share.zoneName, ownerName: identity.share.zoneOwnerName))
        let record: CKRecord
        do { record = try await database.record(for: id) }
        catch {
            try validateEnvironment(identity)
            // This classification is restricted to an exact, previously known
            // participant share in the verified account's shared database.
            if Self.isKnownShareLoss(error) { return (Observation(access: .lost, changeTag: nil), nil) }
            throw error
        }
        try validateEnvironment(identity)
        guard let share = record as? CKShare, share.recordID == id, share.publicPermission == .none else {
            throw PersonalCartError.unavailable
        }
        guard let participant = share.currentUserParticipant, participant.acceptanceStatus == .accepted else {
            return (Observation(access: .lost, changeTag: share.recordChangeTag), share)
        }
        guard participant.role == .privateUser, !participant.__participantID.isEmpty,
              share.participants.contains(where: { $0.__participantID == participant.__participantID }),
              let tag = share.recordChangeTag, !tag.isEmpty else { throw PersonalCartError.unavailable }
        switch participant.permission {
        case .readWrite: return (Observation(access: .writable, changeTag: tag), share)
        case .readOnly: return (Observation(access: .readOnly, changeTag: tag), share)
        default: return (Observation(access: .lost, changeTag: tag), share)
        }
    }

    static func isKnownShareLoss(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        return error.code == .unknownItem || error.code == .permissionFailure || error.code == .zoneNotFound
    }

    private func apply(_ observation: Observation, to pending: Pending) throws {
        let request = pending.request, identity = request.identity
        try cart.transact { repository in
            try validateEnvironment(identity)
            guard persistence.homeNativeAccess.isCurrent(request),
                  let home = try? repository.household(identity.scope.householdID),
                  try repository.nativeAccessIdentity(for: home) == identity else { throw PersonalCartError.scopeChanged }
            let access = try repository.homeEffectAccess(householdID: identity.scope.householdID, listID: identity.scope.listID)
            if observation.access != .writable {
                try persistence.homeNativeAccess.restrict(request, to: observation.access)
            }
            guard let record = try Self.record(observation, identity: identity, access: access,
                capturedRestrictionIDs: pending.restrictionIDs) else { return }
            try repository.insert(id: record.id, kind: "homeAccess", command: record, value: record)
        }
        try validateEnvironment(identity)
        guard persistence.homeNativeAccess.finish(request, access: observation.access) else { throw PersonalCartError.scopeChanged }
    }

    static func record(_ observation: Observation, identity: HomeNativeAccessIdentity,
                       access: HomeEffectAccess, capturedRestrictionIDs: Set<UUID>) throws -> HomeAccessRecord? {
        let action: HomeAccessRecord.Action
        let boundary: Set<UUID>
        switch observation.access {
        case .readOnly:
            action = .readOnly
            boundary = []
        case .lost:
            // Each native observation is independent, even when an intervening
            // rejoin has not imported yet. Retry of this same observation keeps its ID.
            boundary = []
            action = .blocked(.revoked)
        case .writable:
            guard access.hasCompletePermissions, access.restrictionIDs == capturedRestrictionIDs else {
                throw PersonalCartError.scopeChanged
            }
            guard !access.unresolvedRestrictionIDs.isEmpty else { return nil }
            boundary = capturedRestrictionIDs
            action = .writable(observedRestrictionIDs: capturedRestrictionIDs)
        }
        let id = operationID(identity: identity, observation: observation, boundary: boundary)
        let record = HomeAccessRecord(id: id, scope: identity.scope, share: identity.share, action: action)
        try record.validate()
        return record
    }

    static func operationID(identity: HomeNativeAccessIdentity, observation: Observation, boundary: Set<UUID>) -> UUID {
        // Native tags change whenever the server saves the record. Re-reading the
        // same version must not create an import/refresh/private-write feedback loop.
        let access: String
        switch observation.access { case .writable: access = "writable"; case .readOnly: access = "readOnly"; case .lost: access = "lost" }
        let components = [identity.scope.accountBinding, identity.scope.containerIdentifier, identity.scope.environment,
            identity.scope.householdID.uuidString, identity.scope.listID.uuidString, identity.share.recordName,
            identity.share.zoneName, identity.share.zoneOwnerName, access, observation.changeTag ?? "no-version",
            observation.access == .readOnly ? "" : boundary.map(\.uuidString).sorted().joined(separator: ","),
            observation.access == .lost ? observation.id.uuidString : ""]
        let encoded = try! JSONEncoder().encode(components) // Strings are always encodable.
        return PersonalCartCoding.stableID("native-home-access", encoded.base64EncodedString())
    }

    private func validateSession(_ session: ShopperSession) throws {
        guard let provider = persistence.personalCartSessionProvider as? ShopperSessionProvider,
              case .ready(let verified) = provider.state, verified == session,
              try provider.currentSession() == session,
              persistence.personalCartInitialBinding == session.accountBinding else { throw PersonalCartError.accountChanged }
    }

    private func validateEnvironment(_ identity: HomeNativeAccessIdentity) throws {
        guard let provider = persistence.personalCartSessionProvider else { throw PersonalCartError.accountChanged }
        let session = try provider.currentSession()
        try validateSession(session)
        guard HomeEffectScope(session: session, householdID: identity.scope.householdID, listID: identity.scope.listID) == identity.scope,
              case .managed(_, let sharedURL, let containerID) = persistence.configuration,
              containerID == identity.scope.containerIdentifier,
              let store = persistence.store(for: .participantShared), store.identifier == identity.storeIdentifier,
              store.url == sharedURL, sharedURL.deletingLastPathComponent().lastPathComponent == session.accountBinding,
              persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              let description = persistence.container.persistentStoreDescriptions.first(where: { $0.url == sharedURL }),
              description.cloudKitContainerOptions?.databaseScope == .shared,
              description.cloudKitContainerOptions?.containerIdentifier == containerID else { throw PersonalCartError.scopeChanged }
    }
}

extension PersonalCartService {
    func refreshNativeHomeAccessAndReplay(recheckIfRunning: Bool = false) async -> String? {
        await persistence.homeAccessRefreshQueue.run(recheckIfRunning: recheckIfRunning) { [self] in
            let failure = await ManagedHomeAccessObserver(cart: self, persistence: persistence).refresh()
            return await Task.detached(priority: .utility) {
                do { try self.resumePending(); return failure }
                catch { return failure ?? error.localizedDescription }
            }.value
        }
    }
}
