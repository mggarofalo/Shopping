import Foundation

/// Value-only boundary between invitation presentation and account-private commands.
@MainActor
struct HomeNamedInvitationActions {
    let load: () async throws -> [HomeInvitationRecord]
    let prepare: (String) async throws -> HomeInvitationRecord
    let create: (UUID, Bool) async throws -> HomeInvitationDelivery
    let rename: (UUID, String) async throws -> Void
    let label: (String, String) async throws -> HomeInvitationRecord
    let handoff: (UUID) async throws -> Void
    let cancel: (UUID) async throws -> HomeMembershipRemovalConfirmation
    var cancelLink: (UUID, String) async throws -> HomeMembershipRemovalConfirmation = { _, _ in throw HomeMembershipError.invitationUnavailable }
    var discard: (UUID) async throws -> Void = { _ in throw HomeMembershipError.invitationUnavailable }
}
