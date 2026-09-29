import Foundation

/// Native observations belong to one attached graph and share, not a display name.
struct HomeNativeAccessIdentity: Codable, Hashable, Sendable {
    let scope: HomeEffectScope
    let storeIdentifier: String
    let rootURI: String
    let share: HomeEffectShare
}

/// Network-free enforcement shared by the phone and Watch. Durable loss and
/// permission records remain authoritative across launches and devices.
final class HomeNativeAccessGate: @unchecked Sendable {
    enum Access: Sendable { case writable, readOnly, lost }
    struct Request: Equatable, Sendable {
        let identity: HomeNativeAccessIdentity
        let sequence: UInt64
    }
    private struct State {
        let sequence: UInt64
        var access: Access?
        var verified = false
    }
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var states: [HomeNativeAccessIdentity: State] = [:]

    func invalidateVerification() {
        lock.withLock {
            for identity in states.keys {
                sequence &+= 1
                states[identity] = State(sequence: sequence, access: states[identity]?.access)
            }
        }
    }

    func begin(_ identity: HomeNativeAccessIdentity) -> Request {
        lock.withLock {
            sequence &+= 1
            states[identity] = State(sequence: sequence, access: states[identity]?.access)
            return Request(identity: identity, sequence: sequence)
        }
    }

    func isCurrent(_ request: Request) -> Bool {
        lock.withLock { states[request.identity]?.sequence == request.sequence }
    }

    /// Called on the command writer before retaining the corresponding fact.
    /// A failed ledger save keeps this conservative restriction in memory.
    func restrict(_ request: Request, to access: Access) throws {
        try lock.withLock {
            guard states[request.identity]?.sequence == request.sequence else { throw PersonalCartError.scopeChanged }
            guard access != .writable else { throw PersonalCartError.scopeChanged }
            states[request.identity]?.access = access
            states[request.identity]?.verified = false
        }
    }

    /// Writable permission is granted only after the durable transaction succeeds.
    @discardableResult
    func finish(_ request: Request, access: Access) -> Bool {
        lock.withLock {
            guard states[request.identity]?.sequence == request.sequence else { return false }
            states[request.identity]?.access = access
            states[request.identity]?.verified = true
            return true
        }
    }

    func permitsPublication(_ identity: HomeNativeAccessIdentity) -> Bool {
        lock.withLock { states[identity]?.verified == true && states[identity]?.access == .writable }
    }

    func observedAccess(_ identity: HomeNativeAccessIdentity) -> Access? {
        lock.withLock { states[identity]?.access }
    }
}
