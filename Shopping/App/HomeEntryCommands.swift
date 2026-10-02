import Foundation

/// Entry screens issue intents here; bootstrap keeps store and journal ownership.
@MainActor
struct HomeEntryCommands {
    private let bootstrap: PersistenceBootstrap

    init(bootstrap: PersistenceBootstrap) { self.bootstrap = bootstrap }

    func refreshHomes() async throws { try await bootstrap.refreshHomes() }

    func select(_ graph: HomeGraphIdentity) async throws { try await bootstrap.selectHome(graph) }

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
        try await bootstrap.activateInvitedHome(entryID: id, graph: graph)
    }

    func deferInvitation(_ id: UUID) async throws {
        try await bootstrap.keepCurrentHome(entryID: id)
    }

    func retryInvitation(_ id: UUID) { bootstrap.invitations?.retry(id) }

    func dismissInvitation(_ id: UUID) { bootstrap.invitations?.dismiss(id) }

    func openRetainedLocalHome() async throws { try await bootstrap.openRetainedLocalHome() }

    func connectBackToAccount() async throws { try await bootstrap.connectBackToAccount() }
}
