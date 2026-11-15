import Foundation

/// Runs synchronous persistence-writer work on a GCD thread and resumes the
/// caller when it finishes (SHOPPING-277). The iPhone and the Watch both use it
/// for every call into blocking writer work (SHOPPING-288).
///
/// Writer work blocks in `performAndWait` while CloudKit mirroring or another
/// command holds the writer. A `Task.detached` body would park a thread of the
/// cooperative pool, which has only as many threads as the device has cores.
/// A few parked tasks then starve every other task, including `Task.sleep`
/// timers and main-actor resumptions. GCD adds threads for blocked work, so the
/// pool stays free.
enum BlockingWriterWork {
    static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                 _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(with: Result { try work() }) }
        }
    }

    static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated,
                                 _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
        }
    }
}
