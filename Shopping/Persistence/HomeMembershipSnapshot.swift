import Foundation

struct HomeMembershipSnapshot: Equatable, Sendable {
    enum Access: String, Codable, Sendable { case owner, contributor, restricted }
    enum Source: String, Codable, Sendable { case localUnshared, server }

    let scope: ActiveHomeScope
    let share: HomeShareIdentity?
    let homeName: String
    let access: Access
    let currentParticipantID: String?
    let members: [HomeMember]
    let changeTag: String?
    let observedAt: Date
    let source: Source
    var removals: [HomeMembershipRemovalStatus] = []

    var canInvite: Bool { access == .owner }
    var canEditName: Bool { access != .restricted }
    var acceptedOtherCount: Int { members.filter { !$0.isCurrentUser && $0.acceptance == .accepted }.count }
    var pendingCount: Int { members.filter { !$0.isCurrentUser && $0.acceptance == .pending }.count }
    func canResend(_ member: HomeMember) -> Bool {
        member.canResend && !removals.contains { $0.removal.participantIDs.contains(member.id) }
    }
}

struct HomeMember: Equatable, Identifiable, Sendable {
    enum Role: String, Sendable { case owner, contributor, restricted }
    enum Acceptance: String, Sendable { case pending, accepted, unknown }
    let id: String
    let name: String?
    let role: Role
    let acceptance: Acceptance
    let isCurrentUser: Bool
    let canResend: Bool

    var label: String {
        if acceptance == .pending { return "Invitation pending" }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        switch role {
        case .owner: return "Owner"
        case .contributor: return "Contributor"
        case .restricted: return "Member"
        }
    }
}

struct HomeInviteMaterial: Codable, Equatable, Sendable {
    let participantID: String
    let archive: Data
}

struct HomeInvitationDelivery: Identifiable, Sendable {
    let id: UUID
    let scope: ActiveHomeScope
    let participantID: String
    let url: URL
}

protocol HomeMembershipTransport: Sendable {
    func refresh(scope: ActiveHomeScope) async throws -> HomeMembershipSnapshot
    func makeInvitationParticipant(scope: ActiveHomeScope) async throws -> HomeInviteMaterial
    func addInvitation(_ material: HomeInviteMaterial, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot
    func invitationURL(participantID: String, scope: ActiveHomeScope, share: HomeShareIdentity) async throws -> URL
    func retainedRemovals(scope: ActiveHomeScope, share: HomeShareIdentity) async throws -> [HomeMembershipRemoval]
    func retainRemoval(_ removal: HomeMembershipRemoval, scope: ActiveHomeScope) async throws
    func removeParticipants(_ participantIDs: Set<String>, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot
}

enum HomeMembershipError: Error, LocalizedError, Equatable {
    case ownerRequired, unsupportedAccess, scopeChanged, unsupportedVersion
    case shareUnavailable, membershipChanged, invalidParticipant, missingURL
    case outcomeUncertain, invitationAlreadyAccepted, invitationUnavailable, invalidJournal
    case invitationCancelled, noMembersToRemove

    var errorDescription: String? {
        switch self {
        case .ownerRequired: return "Only this home’s owner can manage invitations."
        case .unsupportedAccess: return "This home’s access settings are not supported. Its groceries have been retained."
        case .scopeChanged: return "Your home or iCloud account changed. Return to the original home to continue."
        case .unsupportedVersion: return "Creating invitation links requires iOS 18 or later."
        case .shareUnavailable: return "Sharing is not ready yet. Check again before inviting someone."
        case .membershipChanged: return "The home’s membership changed. Review it before continuing."
        case .invalidParticipant: return "This invitation could not be verified. No replacement invitation was created."
        case .missingURL: return "The invitation link is not available yet. Check the same invitation again."
        case .outcomeUncertain: return "iCloud has not confirmed this invitation. Check it again before creating another."
        case .invitationAlreadyAccepted: return "This invitation has already been accepted. Create a new invitation for another person."
        case .invitationUnavailable: return "This invitation is no longer available. Refresh this home’s members."
        case .invalidJournal: return "The saved invitation could not be verified. Your home and its members have been retained."
        case .invitationCancelled: return "This invitation attempt was cancelled. It will not be sent again."
        case .noMembersToRemove: return "There are no other members or invitations to remove."
        }
    }
}

/// Only this error guarantees that the adapter never invoked a native membership write.
/// Native callback errors must remain uncertain, even if their wording sounds retryable.
struct HomeMembershipNotSubmitted: Error, Sendable {
    let reason: HomeMembershipError
}
