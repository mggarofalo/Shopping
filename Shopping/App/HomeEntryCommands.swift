import Foundation

/// Entry screens issue intents here; bootstrap keeps store and journal ownership.
@MainActor
struct HomeEntryCommands {
    private let bootstrap: PersistenceBootstrap

    init(bootstrap: PersistenceBootstrap) { self.bootstrap = bootstrap }

    func refreshHomes() async throws { try await bootstrap.refreshHomes() }

    func select(_ graph: HomeGraphIdentity) async throws { try await bootstrap.selectHome(graph) }

    func createFirstHome() async throws { try await bootstrap.createFirstHome() }

    func create(name: String = "My Home", resuming: HomeCreationCommand? = nil)
        async throws -> PersistenceBootstrap.CreatedHome {
        try await bootstrap.createHome(name: name, resuming: resuming)
    }

    func pendingCreation() async throws -> HomeCreationCommand? {
        try await bootstrap.pendingHomeCreation()
    }

    func acknowledgeCreation(_ created: PersistenceBootstrap.CreatedHome) async throws {
        try await bootstrap.acknowledgeHomeCreation(created)
    }

    func connectForJoiningKeepingLocalHome() async throws {
        try await bootstrap.connectForJoiningKeepingLocalHome()
    }

    func openInvitation(_ id: UUID, graph: HomeGraphIdentity) async throws {
        try await bootstrap.reopenInvitation(id, graph: graph)
    }

    func joinInvitation(_ id: UUID) async throws { try await bootstrap.joinInvitation(id) }

    func dismissJoin(_ id: UUID) async throws { try await bootstrap.dismissJoin(id) }

    func deferInvitation(_ id: UUID) async throws {
        try await bootstrap.keepCurrentHome(entryID: id)
    }

    func retryInvitation(_ id: UUID) { bootstrap.invitations?.retry(id) }

    func dismissInvitation(_ id: UUID) { bootstrap.invitations?.dismiss(id) }

    func openRetainedLocalHome() async throws { try await bootstrap.openRetainedLocalHome() }

    func connectBackToAccount() async throws { try await bootstrap.connectBackToAccount() }

    func useICloudForRetainedLocalHome() async throws {
        try await bootstrap.useICloudForRetainedLocalHome()
    }

    func useICloudForLocalHome() async throws { try await bootstrap.useICloudForLocalHome() }
    func replaceStarter(_ proposal: HomeReplacementProposal) async throws {
        try await bootstrap.confirmStarterReplacement(expected: proposal)
    }

    func keepBothHomes() { bootstrap.keepStarterAndOpenInvitation() }

    func reviewReplacement(_ id: UUID) async throws {
        guard bootstrap.replacementRecord?.id == id else { throw HomeReplacementError.intentChanged }
        try await bootstrap.retryStarterReplacement()
    }

    func keepStarter(_ id: UUID) async throws {
        guard bootstrap.replacementRecord?.id == id else { throw HomeReplacementError.intentChanged }
        try await bootstrap.keepStarterAfterInterruptedReplacement()
    }

}
