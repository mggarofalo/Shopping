import CloudKit
import CoreData
@testable import Shopping

/// External-service state only. Never manufactures an application snapshot or delivery.
final class StatefulHomeSharingBackend: HomeSharingBackend, @unchecked Sendable {
    enum Failure: Error { case alreadyShared }
    enum SaveOutcome { case succeed, applyThenLoseCompletion, loseCompletionWithoutApplying }
    private let lock = NSLock()
    private var persistence: PersistenceController
    private var store: NSPersistentStore
    private var graphURIs: Set<URL>
    private var associations: Set<URL> = []
    private var persisted: HomeBackendShare?
    private var revision = 0
    private var editable = true
    private var offline = false
    private var linksReady = true
    private var beforeCreate: (@Sendable () async throws -> Void)?
    private var beforeSave: (@Sendable () async throws -> Void)?
    private var nextCreate: SaveOutcome = .succeed
    private var nextSave: SaveOutcome = .succeed
    private var creates = 0
    private var saves = 0
    private var fetches = 0
    private var lookedUp: [[URL]] = []
    let identity = HomeShareIdentity(recordName: "isolated-share", zoneName: "isolated-zone", zoneOwnerName: "isolated-owner")

    init(persistence: PersistenceController, store: NSPersistentStore, graphIDs: [NSManagedObjectID]) {
        self.persistence = persistence
        self.store = store
        graphURIs = Set(graphIDs.map { $0.uriRepresentation() })
    }

    func reconnect(persistence: PersistenceController, store: NSPersistentStore) { lock.withLock { self.persistence = persistence; self.store = store } }
    func setOffline(_ value: Bool) { lock.withLock { offline = value } }
    func setLinksReady(_ value: Bool) { lock.withLock { linksReady = value } }
    func setBeforeCreate(_ action: @escaping @Sendable () async throws -> Void) { lock.withLock { beforeCreate = action } }
    func setBeforeSave(_ action: @escaping @Sendable () async throws -> Void) { lock.withLock { beforeSave = action } }
    func setNextCreate(_ outcome: SaveOutcome) { lock.withLock { nextCreate = outcome } }
    func setNextSave(_ outcome: SaveOutcome) { lock.withLock { nextSave = outcome } }
    func setEditable(_ value: Bool) { lock.withLock { editable = value } }
    var counts: (creates: Int, saves: Int, fetches: Int) { lock.withLock { (creates, saves, fetches) } }
    var associationLookups: [[URL]] { lock.withLock { lookedUp } }
    var share: HomeBackendShare? { lock.withLock { persisted } }

    func associatePrivateObject(_ id: NSManagedObjectID) { lock.withLock { _ = associations.insert(id.uriRepresentation()) } }

    func environment(scope: ActiveHomeScope) throws -> (NSPersistentStore, PersistenceStoreRole) {
        lock.withLock { (store, .ownerPrivate) }
    }

    func associatedShares(_ ids: [NSManagedObjectID]) throws -> [NSManagedObjectID: HomeBackendShare] {
        lock.withLock {
            lookedUp.append(ids.map { $0.uriRepresentation() })
            guard let persisted else { return [:] }
            return Dictionary(uniqueKeysWithValues: ids.filter { associations.contains($0.uriRepresentation()) }.map { ($0, persisted) })
        }
    }

    func canUpdate(_ id: NSManagedObjectID) -> Bool { lock.withLock { editable } }

    func fetch(_ identity: HomeShareIdentity, scope: ActiveHomeScope, role: PersistenceStoreRole) async throws -> HomeBackendShare {
        try lock.withLock {
            fetches += 1
            if offline { throw CKError(.networkUnavailable) }
            guard let persisted, persisted.identity == identity else { throw CKError(.unknownItem) }
            return observed(persisted)
        }
    }

    func create(store: NSPersistentStore, authorize: @escaping @Sendable () throws -> Void,
        prepareGraph: @escaping @Sendable (NSManagedObjectContext) throws -> HomeBackendCreation) async throws -> HomeBackendShare {
        let expectedStore = ObjectIdentifier(store)
        let boundary = lock.withLock { beforeCreate }
        if let boundary { try await boundary() }
        let context = lock.withLock { persistence.container.newBackgroundContext() }
        return try await context.perform {
            try authorize()
            let prepared = try prepareGraph(context)
            if let existing = prepared.existing { return existing }
            try authorize()
            return try self.lock.withLock {
                self.creates += 1
                if self.offline { throw CKError(.networkUnavailable) }
                guard self.graphURIs.contains(prepared.rootID.uriRepresentation()), expectedStore == ObjectIdentifier(self.store) else { throw CKError(.invalidArguments) }
                guard self.persisted == nil else { throw Failure.alreadyShared }
                let outcome = self.nextCreate
                self.nextCreate = .succeed
                if outcome == .loseCompletionWithoutApplying { throw CKError(.networkFailure) }
                self.revision += 1
                let owner = HomeBackendParticipant(id: "owner", role: .owner, permission: .readWrite,
                    acceptance: .accepted, name: "Owner", email: nil, hasInvitationURL: false)
                let created = HomeBackendShare(identity: self.identity, publicPermission: .none, currentParticipantID: owner.id,
                    participants: [owner], changeTag: String(self.revision), backing: nil)
                self.persisted = created
                self.associations.formUnion(self.graphURIs)
                if outcome == .applyThenLoseCompletion { throw CKError(.networkFailure) }
                return self.observed(created)
            }
        }
    }

    func save(_ share: HomeBackendShare, mutation: HomeBackendMutation, store: NSPersistentStore, authorize: @escaping @Sendable () throws -> Void) async throws -> HomeBackendShare {
        let boundary = lock.withLock { beforeSave }
        if let boundary { try await boundary() }
        do { try authorize() } catch { throw HomeMembershipNotSubmitted(reason: error) }
        return try lock.withLock {
            saves += 1
            if offline { throw CKError(.networkUnavailable) }
            guard let current = persisted, current.identity == share.identity,
                  current.changeTag == share.changeTag, store === self.store else { throw CKError(.serverRecordChanged) }
            let outcome = nextSave
            nextSave = .succeed
            if outcome == .loseCompletionWithoutApplying { throw CKError(.networkFailure) }
            var participants = current.participants
            switch mutation {
            case .add(let material):
                guard !participants.contains(where: { $0.id == material.participantID }) else { throw CKError(.serverRecordChanged) }
                participants.append(HomeBackendParticipant(id: material.participantID, role: .privateUser,
                    permission: .readWrite, acceptance: .pending, name: nil, email: nil, hasInvitationURL: true))
            case .remove(let ids): participants.removeAll { ids.contains($0.id) }
            }
            revision += 1
            let saved = HomeBackendShare(identity: current.identity, publicPermission: current.publicPermission,
                currentParticipantID: current.currentParticipantID, participants: participants,
                changeTag: String(revision), backing: nil)
            persisted = saved
            if outcome == .applyThenLoseCompletion { throw CKError(.networkFailure) }
            return observed(saved)
        }
    }

    func invitationURL(_ share: HomeBackendShare, participantID: String) throws -> URL? {
        try lock.withLock {
            if offline { throw CKError(.networkUnavailable) }
            guard linksReady, let current = persisted, current.identity == share.identity,
                  current.participants.contains(where: { $0.id == participantID && $0.acceptance == .pending }) else { return nil }
            return URL(string: "https://example.invalid/isolated-share/" + participantID)
        }
    }

    func accept(_ participantID: String) throws {
        try lock.withLock {
            guard let current = persisted, current.participants.contains(where: { $0.id == participantID && $0.acceptance == .pending }) else {
                throw CKError(.unknownItem)
            }
            revision += 1
            let participants = current.participants.map { participant in
                HomeBackendParticipant(id: participant.id, role: participant.role, permission: participant.permission,
                    acceptance: participant.id == participantID ? .accepted : participant.acceptance,
                    name: participant.name, email: participant.email, hasInvitationURL: participant.id != participantID && participant.hasInvitationURL)
            }
            persisted = HomeBackendShare(identity: current.identity, publicPermission: current.publicPermission,
                currentParticipantID: current.currentParticipantID, participants: participants, changeTag: String(revision), backing: nil)
        }
    }

    private func observed(_ share: HomeBackendShare) -> HomeBackendShare {
        HomeBackendShare(identity: share.identity, publicPermission: share.publicPermission,
            currentParticipantID: share.currentParticipantID, participants: share.participants.map { participant in
                HomeBackendParticipant(id: participant.id, role: participant.role, permission: participant.permission,
                    acceptance: participant.acceptance, name: participant.name, email: participant.email,
                    hasInvitationURL: linksReady && participant.hasInvitationURL)
            }, changeTag: share.changeTag, backing: nil)
    }
}
