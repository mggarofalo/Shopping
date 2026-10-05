import CloudKit
import CoreData

/// Observed native facts; application transports decide which facts authorize actions.
struct HomeBackendParticipant: Equatable, Sendable {
    let id: String
    let role: CKShare.ParticipantRole
    let permission: CKShare.ParticipantPermission
    let acceptance: CKShare.ParticipantAcceptanceStatus
    let name: String?
    let email: String?
    let hasInvitationURL: Bool
}

protocol HomeBackendShareBacking: Sendable {}

struct HomeBackendShare: Sendable {
    let identity: HomeShareIdentity
    let publicPermission: CKShare.ParticipantPermission
    let currentParticipantID: String?
    let participants: [HomeBackendParticipant]
    let changeTag: String?
    /// Opaque SDK lifetime; only the native adapter can inspect it.
    let backing: (any HomeBackendShareBacking)?
}

struct HomeBackendCreation: Sendable {
    let rootID: NSManagedObjectID
    let title: String
    let existing: HomeBackendShare?
}

enum HomeBackendMutation: Sendable {
    case add(HomeInviteMaterial)
    case remove(Set<String>)
}

protocol HomeSharingBackend: Sendable {
    func environment(scope: ActiveHomeScope) throws -> (NSPersistentStore, PersistenceStoreRole)
    func associatedShares(_ ids: [NSManagedObjectID]) throws -> [NSManagedObjectID: HomeBackendShare]
    func canUpdate(_ id: NSManagedObjectID) -> Bool
    func fetch(_ identity: HomeShareIdentity, scope: ActiveHomeScope, role: PersistenceStoreRole) async throws -> HomeBackendShare
    func create(store: NSPersistentStore, authorize: @escaping @Sendable () throws -> Void,
        prepareGraph: @escaping @Sendable (NSManagedObjectContext) throws -> HomeBackendCreation) async throws -> HomeBackendShare
    func save(_ share: HomeBackendShare, mutation: HomeBackendMutation, store: NSPersistentStore, authorize: @escaping @Sendable () throws -> Void) async throws -> HomeBackendShare
    func invitationURL(_ share: HomeBackendShare, participantID: String) throws -> URL?
}
