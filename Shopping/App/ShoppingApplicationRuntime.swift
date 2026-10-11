import Foundation

/// One persistence owner for scene-driven and system-driven entry points.
@MainActor
final class ShoppingApplicationRuntime {
    static let shared = ShoppingApplicationRuntime(bootstrap: .application())

    let bootstrap: PersistenceBootstrap
    let actions = ShoppingActionRouter()

    init(bootstrap: PersistenceBootstrap) { self.bootstrap = bootstrap }

    func ready(timeout: Duration = .seconds(15)) async throws -> PersistenceBootstrap.ReadyState {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            switch bootstrap.state {
            case .ready(let ready):
                guard ready.presentation.isActive, ready.householdID != nil, ready.listID != nil else {
                    throw ShoppingActionError.homeUnavailable
                }
                return ready
            case .failed(let error): throw error
            case .loading: await bootstrap.runLoadingTransition()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ShoppingActionError.loading
    }

    func request(_ destination: ShoppingActionDestination) throws {
        let binding: UUID?
        if case .ready(let ready) = bootstrap.state,
           ready.presentation.isActive, ready.householdID != nil, ready.listID != nil {
            binding = ready.presentation.id
        }
        else { binding = nil }
        try actions.enqueue(destination, presentationID: binding)
    }
}

enum ShoppingActionError: LocalizedError, Equatable {
    case homeUnavailable, loading, busy, scopeChanged

    var errorDescription: String? {
        switch self {
        case .homeUnavailable: return "Open Milk & Bananas and choose an available Home, then try again."
        case .loading: return "Your Home is still opening. Open Milk & Bananas and try again."
        case .busy: return "Finish or cancel the pending action in Milk & Bananas first."
        case .scopeChanged: return "Your Home or account changed. Please start the action again."
        }
    }
}
