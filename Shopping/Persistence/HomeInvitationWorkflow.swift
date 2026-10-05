import Foundation

/// The Invite action has one preparation/authority/membership sequence in app and tests.
@MainActor
enum HomeInvitationWorkflow {
    static func invite(scope: ActiveHomeScope, journalURL: URL,
        coordinator: HomeMembershipCoordinator, transport: any HomeMembershipTransport,
        prepare: () async throws -> PreparedHomeShare,
        validatePresentation: () throws -> Void) async throws -> HomeInvitationDelivery {
        do { _ = try await prepare() }
        catch {
            HomeSharingErrorPresentation.record(error, operation: "Prepare home share")
            throw error
        }
        try validatePresentation()
        let result = try await coordinator.invite(scope: scope, journalURL: journalURL, transport: transport)
        try validatePresentation()
        return result
    }
}
