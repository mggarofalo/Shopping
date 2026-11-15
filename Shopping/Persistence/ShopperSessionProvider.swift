import CloudKit
import CryptoKit
import Foundation
import os

extension Notification.Name {
    static let shopperSessionDidChange = Notification.Name("ShoppingShopperSessionDidChange")
}

// Commands need a synchronous, network-free authority check. The lock protects all session
// state, including invalidation delivered on CloudKit's arbitrary notification queue.
final class ShopperSessionProvider: ShopperSessionProviding, @unchecked Sendable {
    struct AccountLookup: Sendable {
        let status: @Sendable () async throws -> CKAccountStatus
        let recordName: @Sendable () async throws -> String
    }

    private struct CachedBinding: Codable {
        let session: ShopperSession
        let invalidated: Bool
    }

    // Only `signedOut` and an authenticated different binding are definitive account answers.
    // Apple: for temporarilyUnavailable, "Don't delete any cached data"; wait for CKAccountChanged.
    private enum Resolution {
        case authenticated(ShopperSession)
        case signedOut(ShopperSessionError)
        case indeterminate(String)
        case rejected(ShopperSessionError)

        var logDescription: String {
            switch self {
            case .authenticated: return "available"
            case .signedOut(let reason): return "definitive \(reason.rawValue)"
            case .indeterminate: return "indeterminate"
            case .rejected(let reason): return "rejected \(reason.rawValue)"
            }
        }
    }

    // One line per answer, for device diagnosis (SHOPPING-122). Never logs the account record name.
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.mggarofalo.shopping",
        category: "Account")

    private let lock = NSLock()
    private let lookup: AccountLookup
    private let containerIdentifier: String
    private let environment: String
    private let cacheURL: URL
    private let notifications: NotificationCenter
    private var accountObserver: NSObjectProtocol?
    private var storedState: ShopperSessionState = .unresolved
    private var cachedBinding: CachedBinding?
    private var generation: UInt64 = 0

    convenience init(containerIdentifier: String, environment: String, cacheDirectory: URL) throws {
        try Self.validateConfiguration(containerIdentifier: containerIdentifier, environment: environment)
        let container = CKContainer(identifier: containerIdentifier)
        try self.init(
            containerIdentifier: containerIdentifier, environment: environment,
            cacheDirectory: cacheDirectory,
            lookup: AccountLookup(
                status: { try await container.accountStatus() },
                recordName: { try await container.userRecordID().recordName }
            )
        )
    }

    init(
        containerIdentifier: String,
        environment: String,
        cacheDirectory: URL,
        lookup: AccountLookup,
        notifications: NotificationCenter = .default
    ) throws {
        try Self.validateConfiguration(containerIdentifier: containerIdentifier, environment: environment)
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        self.lookup = lookup
        self.notifications = notifications
        let namespace = try JSONEncoder().encode([containerIdentifier, environment])
        let name = SHA256.hash(data: namespace).map { String(format: "%02x", $0) }.joined()
        cacheURL = cacheDirectory.appendingPathComponent(name + ".json")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            do {
                let binding = try JSONDecoder().decode(CachedBinding.self, from: Data(contentsOf: cacheURL))
                guard binding.session.containerIdentifier == containerIdentifier,
                      binding.session.environment == environment, binding.session.isWellFormed else {
                    throw ShopperSessionError.invalidIdentity
                }
                cachedBinding = binding
                if binding.invalidated { storedState = .accountChanged }
            } catch {
                // Keep account-partitioned stores intact. A verified lookup can repair the pointer.
                storedState = .setupRequired(.cacheUnavailable)
            }
        }
        accountObserver = notifications.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) {
            [weak self] _ in self?.accountDidChange()
        }
    }

    deinit {
        if let accountObserver { notifications.removeObserver(accountObserver) }
    }

    var state: ShopperSessionState {
        lock.withLock { storedState }
    }

    func observeSessionChanges(
        _ handler: @escaping @Sendable (ShopperSessionState, ShopperSession?) -> Void
    ) -> NSObjectProtocol {
        notifications.addObserver(forName: .shopperSessionDidChange, object: self, queue: nil) { notification in
            guard let announced = notification.userInfo?["state"] as? ShopperSessionState else { return }
            handler(announced, notification.userInfo?["invalidatedSession"] as? ShopperSession)
        }
    }

    func removeSessionObserver(_ observer: NSObjectProtocol) {
        notifications.removeObserver(observer)
    }

    func currentSession() throws -> ShopperSession {
        try lock.withLock {
            switch storedState {
            case .ready(let session), .cached(let session): return session
            case .accountChanged: throw ShopperSessionError.accountChanged
            case .setupRequired(let reason): throw reason
            case .temporarilyUnavailable: throw ShopperSessionError.temporarilyUnavailable
            case .unresolved: throw ShopperSessionError.setupRequired
            }
        }
    }

    func refresh() async {
        let requestGeneration = lock.withLock { () -> UInt64 in
            generation &+= 1
            return generation
        }
        let resolution: Resolution
        do {
            switch try await lookup.status() {
            case .available:
                let recordName = try await lookup.recordName()
                guard recordName != CKCurrentUserDefaultName, !recordName.isEmpty else {
                    throw ShopperSessionError.invalidIdentity
                }
                resolution = .authenticated(try ShopperSession.authenticated(
                    containerIdentifier: containerIdentifier, environment: environment,
                    accountRecordName: recordName
                ))
            case .noAccount: resolution = .signedOut(.noAccount)
            case .restricted: resolution = .signedOut(.restricted)
            case .couldNotDetermine, .temporarilyUnavailable:
                resolution = .indeterminate(ShopperSessionError.temporarilyUnavailable.localizedDescription)
            @unknown default:
                resolution = .indeterminate(ShopperSessionError.temporarilyUnavailable.localizedDescription)
            }
        } catch let reason as ShopperSessionError {
            resolution = .rejected(reason)
        } catch {
            // Network, server and authentication failures say nothing about which account is signed in.
            let failure = error as NSError
            Self.log.notice("Account lookup failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            resolution = .indeterminate(error.localizedDescription)
        }
        Self.log.notice("Account lookup: \(resolution.logDescription, privacy: .public)")
        let change: (state: ShopperSessionState, invalidatedSession: ShopperSession?)? = lock.withLock {
            guard generation == requestGeneration else { return nil }
            let outgoingSession = cachedBinding?.session
            switch resolution {
            case .authenticated(let session):
                do {
                    let binding = CachedBinding(session: session, invalidated: false)
                    try persist(binding)
                    cachedBinding = binding
                    storedState = .ready(session)
                } catch {
                    // A different account is still a definitive answer, even when its binding can't be saved.
                    if outgoingSession != session { invalidateCache() }
                    storedState = .setupRequired(.cacheUnavailable)
                }
            case .signedOut(let reason):
                invalidateCache()
                storedState = .setupRequired(reason)
            case .indeterminate(let message):
                if let cachedBinding, !cachedBinding.invalidated {
                    storedState = .cached(cachedBinding.session)
                } else {
                    storedState = .temporarilyUnavailable(message)
                }
            case .rejected(let reason):
                storedState = .setupRequired(reason)
            }
            let invalidatedSession: ShopperSession?
            switch storedState {
            case .setupRequired(.noAccount), .setupRequired(.restricted):
                invalidatedSession = outgoingSession
            default:
                invalidatedSession = nil
            }
            return (storedState, invalidatedSession)
        }
        guard let change else {
            Self.log.notice("Account lookup superseded by a newer check")
            return
        }
        Self.log.notice("Account state: \(change.state.logDescription, privacy: .public)")
        announce(change.state, invalidatedSession: change.invalidatedSession)
    }

    // CKAccountChanged is a prompt to re-check, not an answer. The binding stays usable but
    // unverified until the lookup is definitive; commands recheck the binding before writing.
    private func accountDidChange() {
        let unverified: ShopperSessionState? = lock.withLock {
            generation &+= 1 // Ignore any in-flight response from the previous account.
            guard case .ready(let session) = storedState else { return nil }
            storedState = .cached(session)
            return storedState
        }
        Self.log.notice("CKAccountChanged: re-checking")
        if let unverified { announce(unverified) }
        Task { [weak self] in await self?.refresh() }
    }

    // Called only with the lock held. The cache is a pointer, never the grocery database.
    private func invalidateCache() {
        guard let binding = cachedBinding else { return }
        let invalidated = CachedBinding(session: binding.session, invalidated: true)
        cachedBinding = invalidated
        do {
            try persist(invalidated)
        } catch {
            // If atomic replacement fails, remove only the reusable authentication pointer.
            // Retain every account's store and recovery files.
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    private func persist(_ binding: CachedBinding) throws {
        try JSONEncoder().encode(binding).write(to: cacheURL, options: .atomic)
    }

    private func announce(_ state: ShopperSessionState, invalidatedSession: ShopperSession? = nil) {
        var details: [String: Any] = ["state": state]
        if let invalidatedSession { details["invalidatedSession"] = invalidatedSession }
        notifications.post(name: .shopperSessionDidChange, object: self, userInfo: details)
    }

    private static func validateConfiguration(containerIdentifier: String, environment: String) throws {
        guard containerIdentifier.hasPrefix("iCloud."), containerIdentifier.count > 7,
              ["Development", "Production"].contains(environment) else {
            throw ShopperSessionError.invalidConfiguration
        }
    }
}

private extension ShopperSessionState {
    // Names the state only; bindings stay out of device logs.
    var logDescription: String {
        switch self {
        case .unresolved: return "unresolved"
        case .ready: return "ready"
        case .cached: return "cached (using saved account)"
        case .setupRequired(let reason): return "setup required: \(reason.rawValue)"
        case .temporarilyUnavailable: return "temporarily unavailable"
        case .accountChanged: return "account changed"
        }
    }
}
