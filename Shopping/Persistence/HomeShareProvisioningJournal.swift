import Foundation

final class HomeShareProvisioningJournal: @unchecked Sendable {
    struct Intent: Codable, Equatable {
        let id: UUID
        let scope: ActiveHomeScope
        var attempted = false
        var identity: HomeShareIdentity?
    }

    private static let lock = NSLock()
    private let url: URL
    init(url: URL) { self.url = url }

    static func location(storeURL: URL, scope: ActiveHomeScope) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("share-provisioning-" + scope.preferenceNamespace + ".json")
    }

    func existingIntent(scope: ActiveHomeScope) throws -> Intent? {
        try Self.lock.withLock { try load(scope: scope) }
    }

    func begin(scope: ActiveHomeScope) throws -> Intent {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let intent = try load(scope: scope) { return intent }
        let intent = Intent(id: UUID(), scope: scope)
        try save(intent)
        return intent
    }

    func markAttempted(scope: ActiveHomeScope) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard var intent = try load(scope: scope) else { throw HomeSharingError.scopeChanged }
        intent.attempted = true
        try save(intent)
    }

    func associate(_ identity: HomeShareIdentity, scope: ActiveHomeScope) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard var intent = try load(scope: scope) else { throw HomeSharingError.scopeChanged }
        guard intent.identity == nil || intent.identity == identity else { throw HomeSharingError.conflictingShare }
        intent.identity = identity
        try save(intent)
    }

    private func load(scope: ActiveHomeScope) throws -> Intent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let intent = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: url))
        guard intent.scope == scope else { throw HomeSharingError.scopeChanged }
        return intent
    }

    private func save(_ intent: Intent) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(intent).write(to: url, options: .atomic)
    }
}
