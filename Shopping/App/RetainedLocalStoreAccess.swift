import Foundation

/// Reserves the unmounted local source synchronously on the UI owner before
/// starting background persistence work. Store transitions drain this reservation
/// before mounting that source in a new presentation.
@MainActor
final class RetainedLocalStoreAccess {
    private struct Reservation {
        let id: UUID
        let completion: Task<Void, Never>
    }
    private var pending: Reservation?

    func perform<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard pending == nil else { throw HomeReplacementError.operationInProgress }
        let task = Task.detached(priority: .userInitiated, operation: operation)
        let id = UUID()
        pending = Reservation(id: id, completion: Task { _ = await task.result })
        defer { if pending?.id == id { pending = nil } }
        return try await task.value
    }

    func drain() async {
        while let reservation = pending {
            await reservation.completion.value
            if pending?.id == reservation.id { pending = nil }
        }
    }
}
