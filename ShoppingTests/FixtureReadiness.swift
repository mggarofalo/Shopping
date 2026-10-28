import Combine
import Foundation

/// Test-owned completion barrier. Publishers wake it; exact witnesses authorize
/// the next fixture action. A notification alone is never completion evidence.
@MainActor
enum FixtureReadiness {
    struct Timeout: Error, CustomStringConvertible {
        let missing: [String]
        var description: String { "Fixture prerequisites missing: " + missing.joined(separator: "; ") }
    }

    nonisolated static func mismatch<Value: Equatable>(
        _ name: String, actual: Value, expected: Value
    ) -> String? {
        actual == expected ? nil : "\(name): expected \(expected), observed \(actual)"
    }

    static func wait(
        changes: [AnyPublisher<Void, Never>],
        timeout: Duration = .seconds(5),
        missing: @escaping @MainActor () throws -> [String]
    ) async throws {
        try Task.checkCancellation()
        guard !(try missing()).isEmpty else { return }
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // ObservableObject emits before mutation. Evaluate on the next actor
        // turn, and subscribe before rechecking to close the registration gap.
        let subscriptions = changes.map { publisher in
            publisher.sink { _ in
                Task { @MainActor in continuation.yield(()) }
            }
        }
        let deadline = Task { @MainActor in
            do {
                try await Task.sleep(for: timeout)
                continuation.finish()
            } catch { }
        }
        defer {
            deadline.cancel()
            subscriptions.forEach { $0.cancel() }
            continuation.finish()
        }
        continuation.yield(())
        for await _ in events {
            try Task.checkCancellation()
            if try missing().isEmpty { return }
        }
        try Task.checkCancellation()
        throw Timeout(missing: try missing())
    }
}
