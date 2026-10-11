import Foundation

/// A screen's lifetime, not account authentication or durable outbox authority.
/// Writer queues can reject work captured before that screen was retired.
final class UICommandAuthority: @unchecked Sendable {
    enum Failure: Error, Equatable, LocalizedError {
        case retired
        var errorDescription: String? { "Your home or account changed. Reopen this action in its original home." }
    }
    private let lock = NSLock()
    private var active = true
    private let additionalValidation: @Sendable () throws -> Void

    init(validating additionalValidation: @escaping @Sendable () throws -> Void = {}) {
        self.additionalValidation = additionalValidation
    }

    var isActive: Bool { lock.withLock { active } }

    func retire() { lock.withLock { active = false } }

    func validate() throws {
        guard isActive else { throw Failure.retired }
        try additionalValidation()
    }
}
