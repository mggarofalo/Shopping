import Foundation

struct HomeLeaveZone: Equatable, Sendable {
    let name: String
    let ownerName: String

    init(share: HomeEffectShare) {
        name = share.zoneName
        ownerName = share.zoneOwnerName
    }

    init(name: String, ownerName: String) {
        self.name = name
        self.ownerName = ownerName
    }
}

struct HomeLeaveMembership: Sendable {
    struct Participant: Sendable {
        enum Role: Sendable { case owner, privateUser, other }
        enum Acceptance: Sendable { case accepted, pending, other }
        enum Permission: Sendable { case readOnly, readWrite, other }
        let id: String
        let role: Role
        let acceptance: Acceptance
        let permission: Permission
    }

    let share: HomeEffectShare
    let isPrivateShare: Bool
    let currentParticipant: Participant?
    let privateParticipantIDs: Set<String>
}

/// The platform boundary only. The coordinator retains real Core Data graph
/// validation, store attachment checks, private authorization, and checkpoints.
protocol HomeLeaveBackend: Sendable {
    func validateEnvironment(identity: HomeNativeAccessIdentity, storeURL: URL?) throws -> ShopperSession
    /// Called on the repository context's queue; managed objects never escape it.
    func validateMapping(identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws
    func membership(identity: HomeNativeAccessIdentity) async throws -> HomeLeaveMembership
    /// The captured attachment identity prevents a replacement store with the
    /// same URL and persistent identifier from receiving the destructive call.
    func purge(_ command: HomeLeaveCommand, storeIdentity: ObjectIdentifier) async throws -> HomeLeaveZone
    func zoneExists(_ command: HomeLeaveCommand) async throws -> Bool
}
