import Foundation

/// Reserves the unmounted local source synchronously on the UI owner before
/// starting background persistence work. Store transitions drain this reservation
/// before mounting that source in a new presentation.
@MainActor
final class RetainedLocalStoreAccess {
    private var pending: Task<Void, Never>?

    func perform<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard pending == nil else { throw HomeReplacementError.operationInProgress }
        let task = Task.detached(priority: .userInitiated, operation: operation)
        pending = Task { _ = await task.result }
        defer { pending = nil }
        return try await task.value
    }

    func drain() async { await pending?.value }
}
