import Foundation

/// One persistence owner for scene-driven and system-driven entry points.
@MainActor
final class ShoppingApplicationRuntime {
    static let shared = ShoppingApplicationRuntime(bootstrap: .application())

    let bootstrap: PersistenceBootstrap
    let actions = ShoppingActionRouter()

    init(bootstrap: PersistenceBootstrap) { self.bootstrap = bootstrap }

    /// The deadline covers the loading transition too: Siri waits on this call.
    func ready(timeout: Duration = .seconds(15)) async throws -> PersistenceBootstrap.ReadyState {
        try await ShoppingActionDeadline.run(within: timeout, onTimeout: .loading) { @MainActor in
            try await self.awaitReady()
        }
    }

    private func awaitReady() async throws -> PersistenceBootstrap.ReadyState {
        while true {
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
    case homeUnavailable, loading, busy, scopeChanged, timedOut, unavailable

    var errorDescription: String? {
        switch self {
        case .homeUnavailable: return "Open Milk & Bananas and choose an available Home, then try again."
        case .loading: return "Your Home is still opening. Open Milk & Bananas and try again."
        case .busy: return "Finish or cancel the pending action in Milk & Bananas first."
        case .scopeChanged: return "Your Home or account changed. Please start the action again."
        case .timedOut: return "Milk & Bananas didn’t respond in time. Open the app to check your grocery list."
        case .unavailable: return "Milk & Bananas couldn’t update that item. Open the app to review your grocery list."
        }
    }
}

/// Runs blocking store work on a dispatch thread instead of a cooperative-pool thread.
/// `Task.sleep` wakes through that pool, so work parked on a busy or opening store must
/// not occupy it, or it can starve the deadline that bounds it.
enum BlockingStoreWork {
    static func run<Value: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result(catching: work))
            }
        }
    }
}

/// Bounds a system-action wait without waiting for the abandoned work to finish.
/// Store work cannot be interrupted, so a late completion must remain harmless.
/// Run blocking work through `BlockingStoreWork` so the deadline can always fire.
@MainActor
enum ShoppingActionDeadline {
    static func run<Value>(
        within limit: Duration, onTimeout timeoutError: ShoppingActionError,
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                race.contenders = [
                    Task {
                        do { race.finish(.success(try await work())) }
                        catch { race.finish(.failure(error)) }
                    },
                    Task {
                        guard (try? await Task.sleep(for: limit)) != nil else { return }
                        race.finish(.failure(timeoutError))
                    }
                ]
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }

    /// The first outcome resumes the caller; later outcomes are ignored.
    @MainActor private final class Race<Value> {
        var continuation: CheckedContinuation<Value, Error>?
        var contenders: [Task<Void, Never>] = []

        func finish(_ result: Result<Value, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            contenders.forEach { $0.cancel() }
            continuation.resume(with: result)
        }
    }
}
