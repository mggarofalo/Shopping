import Foundation

struct HomeInvitationSnapshot: Sendable {
    let revision: UInt64
    let entries: [HomeInvitationInbox.Entry]
    let hasPendingActivation: Bool
    let currentSession: ShopperSession?
}

struct HomeInvitationWorkResult<Value: Sendable>: Sendable {
    let value: Value
    let snapshot: HomeInvitationSnapshot
}

/// The private serial queue exclusively owns the non-Sendable inbox and its file I/O.
/// Only immutable Sendable values leave that queue; it never publishes UI state.
final class HomeInvitationWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Shopping invitation journal", qos: .userInitiated)
    private let factory: (@Sendable () throws -> HomeInvitationInbox)?
    private var inbox: HomeInvitationInbox?
    private var revision: UInt64 = 0

    /// Transfers exclusive ownership. The caller must not access this inbox afterward.
    init(inbox: HomeInvitationInbox) {
        self.inbox = inbox
        factory = nil
    }

    /// Opening, decoding, and recovery happen lazily on the worker, never the caller.
    init(factory: @escaping @Sendable () throws -> HomeInvitationInbox) {
        self.factory = factory
    }

    /// Submits synchronously so configuration and incoming invitations retain FIFO order.
    /// Completion runs on the worker; the controller publishes its snapshot on MainActor.
    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (HomeInvitationInbox) throws -> Value,
        completion: @escaping @Sendable (Result<HomeInvitationWorkResult<Value>, Swift.Error>) -> Void
    ) {
        queue.async {
            do {
                let inbox: HomeInvitationInbox
                if let existing = self.inbox {
                    inbox = existing
                } else if let factory = self.factory {
                    inbox = try factory()
                    self.inbox = inbox
                } else {
                    throw HomeInvitationInbox.Error.invalidJournal
                }
                let value = try operation(inbox)
                self.revision &+= 1
                let snapshot = HomeInvitationSnapshot(revision: self.revision, entries: inbox.entries,
                    hasPendingActivation: inbox.hasPendingActivation, currentSession: inbox.currentSession)
                completion(.success(HomeInvitationWorkResult(value: value, snapshot: snapshot)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
