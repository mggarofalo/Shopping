import Foundation

/// Coalesces foreground readers, but retains a trailing pass when an import
/// invalidates the verification that is currently in flight.
actor HomeAccessRefreshQueue {
    private var running = false
    private var anotherPass = false
    private var waiters: [CheckedContinuation<String?, Never>] = []
    var pendingRequestCount: Int { waiters.count }

    func run(recheckIfRunning: Bool, operation: @Sendable () async -> String?) async -> String? {
        if running {
            anotherPass = anotherPass || recheckIfRunning
            return await withCheckedContinuation { waiters.append($0) }
        }
        running = true
        var failure: String?
        repeat {
            anotherPass = false
            failure = await operation()
        } while anotherPass
        running = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: failure) }
        return failure
    }
}
