import Foundation

@MainActor
final class HomeReplacementAppEffects: HomeReplacementEffects {
    private weak var bootstrap: PersistenceBootstrap?
    init(bootstrap: PersistenceBootstrap) { self.bootstrap = bootstrap }
    private func owner() throws -> PersistenceBootstrap {
        guard let bootstrap else { throw HomeReplacementError.intentChanged }
        return bootstrap
    }
    func validateIntent(_ proposal: HomeReplacementProposal, target: ActiveHomeScope?) throws {
        try owner().validateReplacementIntent(proposal, target: target)
    }
    func join(_ proposal: HomeReplacementProposal) throws {
        // The system invitation is accepted before the replacement choice is
        // offered. Validate that same imported invitation; never accept another.
        _ = try owner().replacementTarget(proposal)
    }
    func target(_ proposal: HomeReplacementProposal) throws -> ActiveHomeScope? {
        try owner().replacementTarget(proposal)
    }
    func activate(_ target: ActiveHomeScope, proposal: HomeReplacementProposal) async throws {
        try await owner().activateReplacementTarget(target, proposal: proposal)
    }
    func prepareCleanup(_ proposal: HomeReplacementProposal) async throws -> HomeDeletionCommand {
        try await owner().prepareReplacementCleanup(proposal)
    }
    func removeSource(_ command: HomeDeletionCommand, proposal: HomeReplacementProposal,
                      target: ActiveHomeScope) async throws -> HomeDeletionStatus {
        try await owner().removeReplacementSource(command, proposal: proposal, target: target)
    }
}
