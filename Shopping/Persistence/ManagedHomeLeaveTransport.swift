import CoreData
import Foundation

/// Participant-only, explicitly confirmed leave. Local serialization does not
/// make CloudKit operations atomic across devices. Submitted uncertainty remains
/// quarantined until positive postcondition evidence arrives; it is never retried.
final class ManagedHomeLeaveTransport: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case participantRequired, sharedZone, outcomeUncertain
        var errorDescription: String? {
            switch self {
            case .participantRequired: return "Only an accepted member can leave this home."
            case .sharedZone: return "This shared zone contains another home. Leaving it is unavailable."
            case .outcomeUncertain: return "Leaving this home is still being verified. Your cart and history are retained."
            }
        }
    }
    private let cart: PersonalCartService
    private let persistence: PersistenceController
    private let backend: any HomeLeaveBackend

    /// Supply the account's unscoped service: completion may outlive its screen.
    init(cart: PersonalCartService, persistence: PersistenceController,
        backend: (any HomeLeaveBackend)? = nil) {
        self.cart = cart
        self.persistence = persistence
        self.backend = backend ?? CloudKitHomeLeaveBackend(cart: cart, persistence: persistence)
    }

    /// Builds confirmation material without retaining authorization or purging.
    func prepare(identity: HomeNativeAccessIdentity, authority: UICommandAuthority? = nil) async throws -> HomeLeaveCommand {
        try authority?.validate()
        let session = try environment(identity).session
        return try await persistence.homeParticipantOperations.perform(in: HomeParticipantZone(session: session, share: identity.share)) {
            _ = try self.environment(identity)
            let participantID = try await self.participant(identity, expectedID: nil, authority: authority)
            return try await Task.detached(priority: .utility) {
                try authority?.validate()
                return try self.cart.transact(save: false, additionalAuthority: authority) { repository in
                    let environment = try self.environment(identity)
                    let home = try self.graph(identity, repository: repository, store: environment.store)
                    guard let url = environment.store.url else { throw PersonalCartError.scopeChanged }
                    let command = HomeLeaveCommand(id: UUID(), origin: identity, storeURL: url,
                        participantID: participantID, homeName: home.name,
                        evidence: try repository.homeLeaveEvidence(scope: identity.scope), confirmedAt: Date())
                    try command.validate()
                    return command
                }
            }.value
        }
    }

    /// Calling execute is the user's confirmation. A repeated submitted command
    /// only observes completion, even if its original native callback was lost.
    func execute(_ command: HomeLeaveCommand, authority: UICommandAuthority? = nil) async throws -> HomeLeaveStatus {
        try command.validate()
        let session = try environment(command.origin, storeURL: command.storeURL).session
        return try await persistence.homeParticipantOperations.perform(in: HomeParticipantZone(session: session, share: command.origin.share)) {
            if let status = try await self.status(command), status.submitted || status.completed {
                return try await self.reconcileInsideTurn(command)
            }
            try authority?.validate()
            let captured = try self.environment(command.origin, storeURL: command.storeURL)
            let attachmentID = ObjectIdentifier(captured.store)
            _ = try await self.participant(command.origin, expectedID: command.participantID, authority: authority)
            let scoped = authority.map { self.cart.scoped(to: $0) } ?? self.cart
            let submitted = try await Task.detached(priority: .utility) {
                try authority?.validate()
                let store = try self.attachedStore(attachmentID, command: command)
                try scoped.transact(save: false) { repository in
                    _ = try self.graph(command.origin, repository: repository, store: store, authorizationID: command.id)
                }
                try scoped.retainHomeLeave(command)
                // The durable confirmation now owns the operation. Its own
                // quarantine may retire the originating screen immediately.
                return try self.cart.beginHomeLeaveSubmission(command, identity: command.origin, storeURL: command.storeURL)
            }.value
            guard submitted else { throw Failure.outcomeUncertain }
            // From this checkpoint onward a cancellation/error is uncertain, not
            // permission to issue a second destructive native call.
            try await Task.detached(priority: .utility) {
                try self.cart.transact(save: false) { repository in
                    let store = try self.attachedStore(attachmentID, command: command)
                    _ = try self.graph(command.origin, repository: repository,
                        store: store, authorizationID: command.id)
                    try repository.requireCurrentHomeLeaveSubmission(command)
                }
            }.value
            try self.requireStore(captured.store, command: command)
            let zone = HomeLeaveZone(share: command.origin.share)
            let returned = try await self.backend.purge(command, storeIdentity: ObjectIdentifier(captured.store))
            try self.requireStore(captured.store, command: command)
            guard returned == zone else { throw Failure.outcomeUncertain }
            try await self.completeIfLocallyAbsent(command, store: captured.store)
            guard let status = try await self.status(command) else { throw PersonalCartError.incompleteImport }
            return status
        }
    }

    func reconcile(_ command: HomeLeaveCommand) async throws -> HomeLeaveStatus {
        try command.validate()
        let session = try environment(command.origin, storeURL: command.storeURL).session
        return try await persistence.homeParticipantOperations.perform(in: HomeParticipantZone(session: session, share: command.origin.share)) {
            try await self.reconcileInsideTurn(command)
        }
    }

    private func reconcileInsideTurn(_ command: HomeLeaveCommand) async throws -> HomeLeaveStatus {
        guard let status = try await status(command) else { throw PersonalCartError.incompleteImport }
        guard status.submitted, !status.completed else { return status }
        let captured = try environment(command.origin, storeURL: command.storeURL)
        let exists = try await backend.zoneExists(command)
        try requireStore(captured.store, command: command)
        guard !exists else { return status }
        try await completeIfLocallyAbsent(command, store: captured.store)
        guard let completed = try await self.status(command) else { throw PersonalCartError.incompleteImport }
        return completed
    }

    private func completeIfLocallyAbsent(_ command: HomeLeaveCommand, store: NSPersistentStore) async throws {
        let attachmentID = ObjectIdentifier(store)
        try await Task.detached(priority: .utility) {
            let store = try self.attachedStore(attachmentID, command: command)
            // A new context avoids a presentation context's stale registered roots.
            let context = self.persistence.container.newBackgroundContext()
            try context.performAndWait {
                defer { context.reset() }
                try self.requireStore(store, command: command)
                let homes = Household.fetchRequest()
                homes.affectedStores = [store]
                let lists = GroceryList.fetchRequest()
                lists.affectedStores = [store]
                let originalHome = try context.fetch(homes).contains {
                    $0.id == command.origin.scope.householdID || $0.objectID.uriRepresentation().absoluteString == command.origin.rootURI
                }
                let originalList = try context.fetch(lists).contains { $0.id == command.origin.scope.listID }
                guard !originalHome, !originalList else { throw Failure.outcomeUncertain }
            }
            try self.requireStore(store, command: command)
            try self.cart.completeHomeLeave(command)
        }.value
    }

    private func status(_ command: HomeLeaveCommand) async throws -> HomeLeaveStatus? {
        try await Task.detached(priority: .utility) {
            _ = try self.environment(command.origin, storeURL: command.storeURL)
            let status = try self.cart.retainedHomeLeaves().first { $0.id == command.id }
            guard status == nil || status?.command == command else { throw PersonalCartError.corruptRecord }
            return status
        }.value
    }

    private func participant(_ identity: HomeNativeAccessIdentity, expectedID: String?, authority: UICommandAuthority?) async throws -> String {
        try authority?.validate()
        let captured = try environment(identity)
        let membership = try await backend.membership(identity: identity)
        try authority?.validate()
        guard try environment(identity).store === captured.store,
              membership.share == identity.share,
              membership.isPrivateShare, let participant = membership.currentParticipant,
              participant.role == .privateUser, participant.acceptance == .accepted,
              participant.permission == .readOnly || participant.permission == .readWrite,
              !participant.id.isEmpty,
              expectedID == nil || expectedID == participant.id,
              membership.privateParticipantIDs.contains(participant.id) else {
            throw Failure.participantRequired
        }
        return participant.id
    }

    /// All known logical homes and shares in this zone must be this one home.
    /// Unmapped partial shared roots are ambiguous and fail closed.
    private func graph(_ identity: HomeNativeAccessIdentity, repository: PersonalCartRepository,
        store: NSPersistentStore, authorizationID: UUID? = nil) throws -> Household {
        let home = try repository.household(identity.scope.householdID)
        guard home.objectID.persistentStore === store,
              home.objectID.uriRepresentation().absoluteString == identity.rootURI,
              let list = home.groceryList, list.id == identity.scope.listID,
              list.household == home, list.objectID.persistentStore === store else { throw PersonalCartError.scopeChanged }
        let lists = GroceryList.fetchRequest()
        lists.predicate = NSPredicate(format: "id == %@", identity.scope.listID as CVarArg)
        guard try repository.context.count(for: lists) == 1 else { throw PersonalCartError.scopeChanged }
        try backend.validateMapping(identity: identity, in: repository)
        let zone = HomeLeaveZone(share: identity.share)
        let access = try repository.values(HomeAccessRecord.self, kind: "homeAccess")
        for (id, record) in access {
            try record.validate()
            guard id == record.id, record.scope == repository.homeEffectScope(householdID: record.scope.householdID,
                listID: record.scope.listID) else { throw PersonalCartError.corruptRecord }
            if HomeLeaveZone(share: record.share) == zone, record.scope != identity.scope || record.share != identity.share { throw Failure.sharedZone }
        }
        for status in try repository.homeLeaves() where HomeLeaveZone(share: status.command.origin.share) == zone {
            guard status.command.matches(scope: identity.scope, share: identity.share) else { throw Failure.sharedZone }
            guard !status.requiresResolution || status.id == authorizationID else { throw HomeLeaveError.pendingLeave }
        }
        return home
    }

    private func requireStore(_ captured: NSPersistentStore, command: HomeLeaveCommand) throws {
        guard try environment(command.origin, storeURL: command.storeURL).store === captured else { throw PersonalCartError.scopeChanged }
    }

    private func attachedStore(_ attachmentID: ObjectIdentifier, command: HomeLeaveCommand) throws -> NSPersistentStore {
        let store = try environment(command.origin, storeURL: command.storeURL).store
        guard ObjectIdentifier(store) == attachmentID else { throw PersonalCartError.scopeChanged }
        return store
    }

    private func environment(_ identity: HomeNativeAccessIdentity, storeURL: URL? = nil) throws
        -> (session: ShopperSession, store: NSPersistentStore) {
        let session = try backend.validateEnvironment(identity: identity, storeURL: storeURL)
        guard cart.persistence === persistence, try cart.sessionProvider.currentSession() == session,
              cart.initialAccountBinding == session.accountBinding,
              persistence.personalCartInitialBinding == session.accountBinding,
              identity.scope == HomeEffectScope(session: session, householdID: identity.scope.householdID,
                listID: identity.scope.listID) else { throw PersonalCartError.accountChanged }
        let stores = persistence.container.persistentStoreCoordinator.persistentStores.filter {
            $0.identifier == identity.storeIdentifier
        }
        guard stores.count == 1, let store = stores.first, let url = store.url,
              storeURL == nil || storeURL?.standardizedFileURL == url.standardizedFileURL else {
            throw PersonalCartError.scopeChanged
        }
        return (session, store)
    }
}
