import CloudKit
import CryptoKit
import Foundation

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

    private enum Resolution {
        case authenticated(ShopperSession)
        case unavailable(ShopperSessionError)
        case failed(Error)
    }

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
            case .noAccount: resolution = .unavailable(.noAccount)
            case .restricted: resolution = .unavailable(.restricted)
            case .couldNotDetermine, .temporarilyUnavailable:
                resolution = .unavailable(.temporarilyUnavailable)
            @unknown default: resolution = .unavailable(.temporarilyUnavailable)
            }
        } catch {
            resolution = .failed(error)
        }
        let changedState: ShopperSessionState? = lock.withLock {
            guard generation == requestGeneration else { return nil }
            switch resolution {
            case .authenticated(let session):
                do {
                    let binding = CachedBinding(session: session, invalidated: false)
                    try persist(binding)
                    cachedBinding = binding
                    storedState = .ready(session)
                } catch {
                    storedState = .setupRequired(.cacheUnavailable)
                }
            case .unavailable(let reason):
                invalidateCache()
                storedState = reason == .temporarilyUnavailable
                    ? .temporarilyUnavailable(reason.localizedDescription) : .setupRequired(reason)
            case .failed(let error):
                if Self.isNetworkUnavailable(error), let cachedBinding, !cachedBinding.invalidated {
                    storedState = .cached(cachedBinding.session)
                } else if let reason = error as? ShopperSessionError {
                    invalidateCache()
                    storedState = .setupRequired(reason)
                } else {
                    // A server/configuration/authentication failure is not evidence of offline identity.
                    invalidateCache()
                    storedState = .temporarilyUnavailable(error.localizedDescription)
                }
            }
            return storedState
        }
        if let changedState { announce(changedState) }
    }

    private func accountDidChange() {
        let newState: ShopperSessionState = lock.withLock {
            generation &+= 1 // Ignore any in-flight response from the previous account.
            invalidateCache()
            storedState = .accountChanged
            return storedState
        }
        announce(newState)
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

    private func announce(_ state: ShopperSessionState) {
        notifications.post(name: .shopperSessionDidChange, object: self, userInfo: ["state": state])
    }

    private static func validateConfiguration(containerIdentifier: String, environment: String) throws {
        guard containerIdentifier.hasPrefix("iCloud."), containerIdentifier.count > 7,
              ["Development", "Production"].contains(environment) else {
            throw ShopperSessionError.invalidConfiguration
        }
    }

    private static func isNetworkUnavailable(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        return cloudError.code == .networkUnavailable || cloudError.code == .networkFailure
    }
}
