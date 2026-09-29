import CoreData

/// Native membership is an explicit asynchronous boundary, separate from the
/// private ledger transaction. Local fixtures substitute this boundary only.
protocol HomeRejoinVerifying: Sendable {
    func validate(_ identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws
    func refresh(_ identity: HomeNativeAccessIdentity) async throws
}

struct ManagedHomeRejoinVerifier: HomeRejoinVerifying {
    let cart: PersonalCartService

    func validate(_ identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws {
        guard let provider = cart.sessionProvider as? ShopperSessionProvider,
              case .ready(let session) = provider.state, session == repository.session,
              cart.persistence === repository.persistence,
              cart.persistence.personalCartInitialBinding == session.accountBinding else { throw PersonalCartError.accountChanged }
        let home = try repository.household(identity.scope.householdID)
        guard try repository.nativeAccessIdentity(for: home) == identity else { throw PersonalCartError.scopeChanged }
    }

    func refresh(_ identity: HomeNativeAccessIdentity) async throws {
        // This path verifies exact accepted private membership and records current
        // read-only/read-write permission. It never creates a membership grant.
        _ = try await ManagedHomeAccessObserver(cart: cart, persistence: cart.persistence).verifiedShare(identity)
    }
}
