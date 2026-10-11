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


extension HomeDetailsActions {
    /// A detail presentation retains its original account/store lifetime even when
    /// its target differs from the selected grocery Home.
    func validating(_ validate: @escaping () throws -> Void) -> HomeDetailsActions {
        HomeDetailsActions(
            refresh: { try validate(); return try await refresh() },
            pending: { try validate(); return try await pending() },
            invite: { retry in try validate(); return try await invite(retry) },
            resend: { id in try validate(); return try await resend(id) },
            acknowledge: { value in try validate(); try await acknowledge(value) },
            rename: { name in try validate(); try await rename(name) },
            removals: removals.map { actions in HomeDetailsRemovalActions(
                prepare: { purpose, id in try validate(); return try await actions.prepare(purpose, id) },
                confirm: { value in try validate(); return try await actions.confirm(value) },
                retry: { try validate(); return try await actions.retry() }) },
            leave: leave.map { actions in HomeDetailsLeaveActions(
                prepare: { try validate(); return try await actions.prepare() },
                confirm: { value in try validate(); return try await actions.confirm(value) }) },
            deletion: deletion.map { actions in HomeDetailsDeletionActions(
                prepare: { try validate(); return try await actions.prepare() },
                confirm: { value in try validate(); return try await actions.confirm(value) },
                reconcile: actions.reconcile) },
            preparationNeedsRetry: preparationNeedsRetry.map { action in { try validate(); return try await action() } },
            namedInvitations: namedInvitations)
    }
}
