import Foundation

/// Bounds the presentation wait, even when a native callback or writer cannot
/// be cancelled. The operation keeps its reservation until it actually returns.
@MainActor
final class HomeSharingStatusCheck<Value: Sendable> {
    enum Outcome {
        case value(Value)
        case failed
        case timedOut
        case cancelled
        case alreadyRunning
    }

    private var operationID: UUID?
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private let waitForDeadline: @Sendable () async throws -> Void

    init(waitForDeadline: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(10))
    }) {
        self.waitForDeadline = waitForDeadline
    }

    var isRunning: Bool { operationID != nil }

    func run(_ work: @escaping @MainActor () async throws -> Value) async -> Outcome {
        guard operationID == nil else { return .alreadyRunning }
        guard !Task.isCancelled else { return .cancelled }
        let id = UUID()
        operationID = id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                operation = Task { [weak self] in
                    let outcome: Outcome
                    do { outcome = .value(try await work()) }
                    catch { outcome = Task.isCancelled ? .cancelled : .failed }
                    self?.finished(id: id, outcome: outcome)
                }
                deadline = Task { [weak self, waitForDeadline] in
                    guard !Task.isCancelled else { return }
                    do { try await waitForDeadline() }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    self?.stopWaiting(id: id, outcome: .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopWaiting(id: id, outcome: .cancelled) }
        }
    }

    /// Invalidate a retired account/home presentation without releasing a writer
    /// reservation early. A later read can start after the old operation drains.
    func invalidate() {
        guard let id = operationID else { return }
        stopWaiting(id: id, outcome: .cancelled)
    }

    private func stopWaiting(id: UUID, outcome: Outcome) {
        guard operationID == id else { return }
        deadline?.cancel()
        deadline = nil
        operation?.cancel()
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: outcome)
    }

    private func finished(id: UUID, outcome: Outcome) {
        guard operationID == id else { return }
        deadline?.cancel()
        deadline = nil
        operation = nil
        operationID = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: outcome)
    }
}
