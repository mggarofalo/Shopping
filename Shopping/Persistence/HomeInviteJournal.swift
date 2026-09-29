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
        var version: Int
        var scope: ActiveHomeScope?
        var intent: Intent?
        var archivedInvitations: [Intent]?
        var removals: [HomeMembershipRemovalStatus]?
    }

    private static let lock = NSLock()
    private let url: URL
    init(url: URL) { self.url = url }

    func load(scope: ActiveHomeScope) throws -> Intent? {
        try Self.lock.withLock { try read(scope: scope).intent }
    }

    func begin(scope: ActiveHomeScope, share: HomeShareIdentity, material: HomeInviteMaterial,
               baseChangeTag: String?) throws -> Intent {
        try Self.lock.withLock {
            var state = try read(scope: scope)
            if let existing = state.intent {
                guard existing.share == share else { throw HomeMembershipError.membershipChanged }
                return existing
            }
            guard !material.participantID.isEmpty, !material.archive.isEmpty else { throw HomeMembershipError.invalidParticipant }
            guard !Self.suppressed(in: state).contains(material.participantID) else { throw HomeMembershipError.invitationCancelled }
            let intent = Intent(id: UUID(), scope: scope, share: share, material: material,
                baseChangeTag: baseChangeTag, phase: .prepared)
            state.intent = intent
            try write(state)
            return intent
        }
    }

    func update(_ intent: Intent) throws {
        try Self.lock.withLock {
            var state = try read(scope: intent.scope)
            guard !Self.suppressed(in: state).contains(intent.material.participantID) else { throw HomeMembershipError.invitationCancelled }
            guard let existing = state.intent, existing.id == intent.id,
                  existing.share == intent.share, existing.material == intent.material else {
                throw HomeMembershipError.invalidJournal
            }
            state.intent = intent
            try write(state)
        }
    }

    func acknowledge(id: UUID, participantID: String, scope: ActiveHomeScope) throws {
        try Self.lock.withLock {
            var state = try read(scope: scope)
            guard let intent = state.intent, intent.id == id,
                  intent.material.participantID == participantID else { return }
            guard intent.phase == .applied else { throw HomeMembershipError.outcomeUncertain }
            state.intent = nil
            try write(state)
        }
    }

    /// Private authorization commits first. Import can recover a crash before this
    /// local checkpoint, suppressing the old capability before a later URL lookup.
    func importRemovals(_ removals: [HomeMembershipRemoval], scope: ActiveHomeScope, share: HomeShareIdentity) throws {
        try Self.lock.withLock {
            var state = try read(scope: scope)
            var values = Dictionary(uniqueKeysWithValues: (state.removals ?? []).map { ($0.id, $0) })
            for removal in removals {
                try removal.validate()
                guard removal.matches(scope: scope, share: share) else { throw HomeMembershipError.scopeChanged }
                if let existing = values[removal.id] {
                    guard existing.removal == removal else { throw HomeMembershipError.invalidJournal }
                } else { values[removal.id] = HomeMembershipRemovalStatus(removal: removal) }
            }
            state.removals = values.values.sorted { $0.id.uuidString < $1.id.uuidString }
            if let active = state.intent, Self.suppressed(in: state).contains(active.material.participantID) {
                state.archivedInvitations = (state.archivedInvitations ?? []) + [active]
                state.intent = nil
            }
            try write(state)
        }
    }

    func removals(scope: ActiveHomeScope) throws -> [HomeMembershipRemovalStatus] {
        try Self.lock.withLock { try read(scope: scope).removals ?? [] }
    }

    func isSuppressed(_ participantID: String, scope: ActiveHomeScope) throws -> Bool {
        try Self.lock.withLock { Self.suppressed(in: try read(scope: scope)).contains(participantID) }
    }

    func observed(_ snapshot: HomeMembershipSnapshot) throws {
        try Self.lock.withLock {
            var state = try read(scope: snapshot.scope)
            let present = Set(snapshot.members.map(\.id))
            state.removals = try (state.removals ?? []).map { status in
                guard let share = snapshot.share, status.removal.matches(scope: snapshot.scope, share: share) else {
                    throw HomeMembershipError.membershipChanged
                }
                var updated = status
                updated.absentObservedAt = status.removal.participantIDs.isDisjoint(with: present) ? snapshot.observedAt : nil
                if updated.absentObservedAt != nil { updated.requiresRetry = false }
                return updated
            }
            try write(state)
        }
    }

    func markRemovalAttempt(participantIDs: Set<String>, scope: ActiveHomeScope) throws {
        try Self.lock.withLock {
            var state = try read(scope: scope)
            state.removals = (state.removals ?? []).map { status in
                var updated = status
                if !status.removal.participantIDs.isDisjoint(with: participantIDs) { updated.requiresRetry = true }
                return updated
            }
            try write(state)
        }
    }

    private static func suppressed(in state: Envelope) -> Set<String> {
        (state.removals ?? []).reduce(into: Set<String>()) { $0.formUnion($1.removal.participantIDs) }
    }

    private func read(scope: ActiveHomeScope) throws -> Envelope {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Envelope(version: 2, scope: scope, archivedInvitations: [], removals: [])
        }
        var envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)) }
        catch { throw HomeMembershipError.invalidJournal }
        guard envelope.version == 1 || envelope.version == 2 else { throw HomeMembershipError.invalidJournal }
        if envelope.version == 1 {
            guard let intent = envelope.intent else { throw HomeMembershipError.invalidJournal }
            envelope.scope = intent.scope
            envelope.archivedInvitations = []
            envelope.removals = []
        }
        guard envelope.archivedInvitations != nil, envelope.removals != nil else {
            throw HomeMembershipError.invalidJournal
        }
        guard envelope.scope == scope else { throw HomeMembershipError.scopeChanged }
        for intent in (envelope.archivedInvitations ?? []) + [envelope.intent].compactMap({ $0 }) {
            guard intent.scope == scope, !intent.material.participantID.isEmpty, !intent.material.archive.isEmpty,
                  !intent.share.recordName.isEmpty, !intent.share.zoneName.isEmpty, !intent.share.zoneOwnerName.isEmpty else {
                throw HomeMembershipError.invalidJournal
            }
        }
        let removals = envelope.removals ?? []
        guard Set(removals.map(\.id)).count == removals.count else { throw HomeMembershipError.invalidJournal }
        for status in removals {
            try status.removal.validate()
            guard status.removal.matches(scope: scope, share: status.removal.share) else { throw HomeMembershipError.invalidJournal }
        }
        if let active = envelope.intent, Self.suppressed(in: envelope).contains(active.material.participantID) {
            throw HomeMembershipError.invalidJournal
        }
        envelope.version = 2
        return envelope
    }

    private func write(_ envelope: Envelope) throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        var options: Data.WritingOptions = .atomic
        #if os(iOS) || os(watchOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(envelope).write(to: url, options: options)
    }
}
