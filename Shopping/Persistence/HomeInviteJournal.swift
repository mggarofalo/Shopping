import Foundation

/// Worker-only, account/home/share-bound storage. The coordinator owns effect ordering.
final class HomeInviteJournal {
    enum Phase: String, Codable, Sendable { case prepared, submitted, applied }

    struct Intent: Codable, Equatable, Sendable {
        let id: UUID
        let scope: ActiveHomeScope
        let share: HomeShareIdentity
        let material: HomeInviteMaterial
        var baseChangeTag: String?
        var phase: Phase
    }

    private struct Envelope: Codable {
        let version: Int
        let intent: Intent
    }

    private static let lock = NSLock()
    private let url: URL
    init(url: URL) { self.url = url }

    func load(scope: ActiveHomeScope) throws -> Intent? {
        try Self.lock.withLock { try read(scope: scope) }
    }

    func begin(scope: ActiveHomeScope, share: HomeShareIdentity, material: HomeInviteMaterial,
               baseChangeTag: String?) throws -> Intent {
        try Self.lock.withLock {
            if let existing = try read(scope: scope) {
                guard existing.share == share else { throw HomeMembershipError.membershipChanged }
                return existing
            }
            guard !material.participantID.isEmpty, !material.archive.isEmpty else { throw HomeMembershipError.invalidParticipant }
            let intent = Intent(id: UUID(), scope: scope, share: share, material: material,
                baseChangeTag: baseChangeTag, phase: .prepared)
            try write(intent)
            return intent
        }
    }

    func update(_ intent: Intent) throws {
        try Self.lock.withLock {
            guard let existing = try read(scope: intent.scope), existing.id == intent.id,
                  existing.share == intent.share, existing.material == intent.material else {
                throw HomeMembershipError.invalidJournal
            }
            try write(intent)
        }
    }

    func acknowledge(id: UUID, participantID: String, scope: ActiveHomeScope) throws {
        try Self.lock.withLock {
            guard let intent = try read(scope: scope), intent.id == id,
                  intent.material.participantID == participantID else { return }
            guard intent.phase == .applied else { throw HomeMembershipError.outcomeUncertain }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func read(scope: ActiveHomeScope) throws -> Intent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)) }
        catch { throw HomeMembershipError.invalidJournal }
        guard envelope.version == 1, !envelope.intent.material.participantID.isEmpty,
              !envelope.intent.material.archive.isEmpty, !envelope.intent.share.recordName.isEmpty,
              !envelope.intent.share.zoneName.isEmpty, !envelope.intent.share.zoneOwnerName.isEmpty else {
            throw HomeMembershipError.invalidJournal
        }
        guard envelope.intent.scope == scope else { throw HomeMembershipError.scopeChanged }
        return envelope.intent
    }

    private func write(_ intent: Intent) throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        var options: Data.WritingOptions = .atomic
        #if os(iOS) || os(watchOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(Envelope(version: 1, intent: intent)).write(to: url, options: options)
    }
}
