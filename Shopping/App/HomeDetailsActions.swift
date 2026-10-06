import Foundation

@MainActor
struct HomeDetailsActions {
    let refresh: () async throws -> HomeMembershipSnapshot
    let pending: () async throws -> HomeMembershipCoordinator.Pending?
    let invite: (_ retryPreparation: Bool) async throws -> HomeInvitationDelivery
    let resend: (String) async throws -> HomeInvitationDelivery
    let acknowledge: (HomeInvitationDelivery) async throws -> Void
    let rename: (String) async throws -> Void
    var removals: HomeDetailsRemovalActions? = nil
    var leave: HomeDetailsLeaveActions? = nil
    var deletion: HomeDetailsDeletionActions? = nil
    var preparationNeedsRetry: (() async throws -> Bool)? = nil
    var namedInvitations: HomeNamedInvitationActions? = nil
}

@MainActor
struct HomeDetailsRemovalActions {
    let prepare: (HomeMembershipRemoval.Purpose, String?) async throws -> HomeMembershipRemovalConfirmation
    let confirm: (HomeMembershipRemovalConfirmation) async throws -> HomeMembershipSnapshot
    let retry: () async throws -> HomeMembershipSnapshot
}

@MainActor
struct HomeDetailsLeaveActions {
    let prepare: () async throws -> HomeLeaveCommand
    let confirm: (HomeLeaveCommand) async throws -> HomeLeaveStatus
}

@MainActor
struct HomeDetailsDeletionActions {
    let prepare: () async throws -> HomeDeletionCommand
    let confirm: (HomeDeletionCommand) async throws -> HomeDeletionStatus
    let reconcile: (HomeDeletionCommand) async throws -> HomeDeletionStatus
}
