import Foundation

struct HomeInvitationIdentity: Codable, Equatable, Sendable {
    let containerIdentifier: String
    let environment: String
    let share: HomeShareIdentity
}

/// One app-owned inbox outlives scenes and store transitions. Metadata is an opaque,
/// securely archived capability; the native adapter validates it before any effect.
/// Production access is confined to HomeInvitationWorker's private serial queue.
final class HomeInvitationInbox {
    enum Failure: Codable, Equatable, Sendable {
        case interrupted, accountChanged, acceptance(String)
    }

    enum State: Codable, Equatable, Sendable {
        case queued, joining, loading, ready(HomeGraphIdentity), failed(Failure), dismissed
    }

    struct Entry: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        let identity: HomeInvitationIdentity
        var metadataArchive: Data
        var displayName: String?
        var session: ShopperSession?
        var sharedStoreIdentifier: String?
        var state: State = .queued
        var dismissalRequested = false
        var acceptanceAttempted = false
        var activationResolved = false
        var participantPending = false
        var requiresNativeAcceptance = false
        /// System acceptance or an explicit Join requests opening after exact import.
        /// Dismissal and a newer home choice clear this durably without cancelling acceptance.
        var openRequested = false

        init(id: UUID, identity: HomeInvitationIdentity, metadataArchive: Data,
             displayName: String? = nil, session: ShopperSession?) {
            self.id = id
            self.identity = identity
            self.metadataArchive = metadataArchive
            self.displayName = displayName
            self.session = session
        }

        private enum CodingKeys: String, CodingKey {
            case id, identity, metadataArchive, displayName, session, sharedStoreIdentifier, state
            case dismissalRequested, acceptanceAttempted, activationResolved
            case participantPending, requiresNativeAcceptance
            case openRequested
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            identity = try values.decode(HomeInvitationIdentity.self, forKey: .identity)
            metadataArchive = try values.decode(Data.self, forKey: .metadataArchive)
            displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
            session = try values.decodeIfPresent(ShopperSession.self, forKey: .session)
            sharedStoreIdentifier = try values.decodeIfPresent(String.self, forKey: .sharedStoreIdentifier)
            state = try values.decode(State.self, forKey: .state)
            dismissalRequested = try values.decode(Bool.self, forKey: .dismissalRequested)
            acceptanceAttempted = try values.decode(Bool.self, forKey: .acceptanceAttempted)
            activationResolved = try values.decode(Bool.self, forKey: .activationResolved)
            participantPending = try values.decodeIfPresent(Bool.self, forKey: .participantPending) ?? false
            requiresNativeAcceptance = try values.decodeIfPresent(Bool.self, forKey: .requiresNativeAcceptance) ?? false
            openRequested = try values.decodeIfPresent(Bool.self, forKey: .openRequested) ?? false
        }
    }

    struct Attempt: Equatable, Sendable {
        let id: UUID
        let entryID: UUID
        let identity: HomeInvitationIdentity
        let metadataArchive: Data
        let session: ShopperSession
        let sharedStoreIdentifier: String
        let requiresNativeAcceptance: Bool
        fileprivate let generation: UInt64
    }

    enum Error: Swift.Error, LocalizedError {
        case invalidJournal, unsupportedVersion, invalidInvitation, accountRequired
        case accountMismatch, busy, invalidState, storeChanged

        var errorDescription: String? {
            switch self {
            case .invalidJournal, .unsupportedVersion:
                return "Saved invitations could not be opened. They have been retained."
            case .invalidInvitation: return "This invitation does not match this app’s iCloud configuration."
            case .accountRequired: return "Connect to iCloud before joining this home."
            case .accountMismatch: return "This invitation belongs to another iCloud account."
            case .busy: return "Another invitation is still being processed."
            case .invalidState: return "This invitation cannot perform that action yet."
            case .storeChanged: return "The invitation’s shared store changed. Reopen it in its original account."
            }
        }
    }

    private struct Journal: Codable {
        var version = 1
        var entries: [Entry]
    }

    private(set) var entries: [Entry]
    private(set) var currentSession: ShopperSession? = nil
    private let url: URL
    private let containerIdentifier: String
    private let environment: String
    private var generation: UInt64 = 0
    private var inFlight: Attempt?

    var isAcceptanceInFlight: Bool { inFlight != nil }

    var entriesForCurrentSession: [Entry] {
        entries.filter { $0.session == nil || $0.session == currentSession }
    }

    /// Remains true after a successful import, and after dismissing an attempted join,
    /// until explicit downstream adoption resolves it. Discovery must not auto-select it.
    var hasPendingActivation: Bool {
        // A cached account may start discovery before fresh authentication. Preserve
        // every unresolved hold until we can safely partition it by verified account.
        (currentSession == nil ? entries : entriesForCurrentSession).contains {
            !$0.activationResolved && ($0.state != .dismissed || $0.acceptanceAttempted)
        }
    }

    init(url: URL, containerIdentifier: String, environment: String) throws {
        self.url = url
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        if FileManager.default.fileExists(atPath: url.path) {
            let journal: Journal
            do { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url)) }
            catch { throw Error.invalidJournal }
            guard journal.version == 1 else { throw Error.unsupportedVersion }
            guard Set(journal.entries.map(\.id)).count == journal.entries.count,
                  journal.entries.allSatisfy({ entry in
                      entry.identity.containerIdentifier == containerIdentifier
                          && entry.identity.environment == environment && !entry.metadataArchive.isEmpty
                          && (entry.session == nil || (entry.session?.containerIdentifier == containerIdentifier
                              && entry.session?.environment == environment && entry.session?.isWellFormed == true))
                  }) else { throw Error.invalidJournal }
            entries = journal.entries
        } else { entries = [] }
        let recovered = entries.map { entry -> Entry in
            var entry = entry
            if entry.state == .joining { entry.state = .failed(.interrupted) }
            return entry
        }
        if recovered != entries { try commit(recovered) }
    }

    /// Only pass a session freshly verified by the account provider (.ready, not .cached).
    /// Binding is durable before acceptance; old account entries are never rebound.
    func setSession(_ session: ShopperSession?) throws {
        if let session {
            guard session.isWellFormed, session.containerIdentifier == containerIdentifier,
                  session.environment == environment else { throw Error.accountMismatch }
        }
        guard currentSession != session else { return }
        // Invalidate callbacks even if persisting the newly bound queue fails.
        generation &+= 1
        currentSession = nil
        if let session {
            var updated = entries.filter { $0.session != nil }
            for var entry in entries where entry.session == nil {
                // A cold-launch duplicate may arrive before account authentication.
                if let index = updated.firstIndex(where: { $0.identity == entry.identity && $0.session == session }) {
                    if entry.state == .queued {
                        Self.reopen(&updated[index], metadataArchive: entry.metadataArchive,
                            displayName: entry.displayName, participantPending: entry.participantPending)
                        // The cold delivery is newer than the bound entry. Its
                        // durable Not Now/Open choice must survive deduplication.
                        updated[index].openRequested = entry.openRequested
                    }
                    continue
                }
                entry.session = session
                updated.append(entry)
            }
            try commit(updated)
        }
        currentSession = session
    }

    @discardableResult
    func enqueue(identity: HomeInvitationIdentity, metadataArchive: Data,
                 displayName: String? = nil, participantPending: Bool = false) throws -> Entry {
        guard identity.containerIdentifier == containerIdentifier, identity.environment == environment,
              !identity.share.recordName.isEmpty, !identity.share.zoneName.isEmpty,
              !identity.share.zoneOwnerName.isEmpty, !metadataArchive.isEmpty else { throw Error.invalidInvitation }
        if let index = entries.firstIndex(where: { $0.identity == identity && $0.session == currentSession }) {
            let invalidatesImport: Bool
            switch entries[index].state {
            case .loading, .ready: invalidatesImport = participantPending
            default: invalidatesImport = false
            }
            var updated = entries
            Self.reopen(&updated[index], metadataArchive: metadataArchive,
                displayName: displayName, participantPending: participantPending)
            if updated != entries { try commit(updated) }
            // A renewed grant invalidates work that inspected the previous membership,
            // even if its callback arrives after the renewed acceptance reaches .loading.
            if invalidatesImport { generation &+= 1 }
            return entries[index]
        }
        var entry = Entry(id: UUID(), identity: identity, metadataArchive: metadataArchive,
            displayName: displayName, session: currentSession)
        entry.participantPending = participantPending
        entry.openRequested = true
        try commit(entries + [entry])
        return entry
    }

    func beginAcceptance(id: UUID, sharedStoreIdentifier: String) throws -> Attempt {
        guard inFlight == nil else { throw Error.busy }
        let index = try currentIndex(id)
        guard entries[index].state == .queued else { throw Error.invalidState }
        let attempt = try makeAttempt(entries[index], store: sharedStoreIdentifier)
        var updated = entries
        updated[index].state = .joining
        updated[index].acceptanceAttempted = true
        updated[index].sharedStoreIdentifier = sharedStoreIdentifier
        try commit(updated)
        inFlight = attempt
        return attempt
    }

    /// Always deliver the native callback, even when its waiter was dismissed or retired.
    /// A stale success records progress only for the original account; it grants no UI authority.
    @discardableResult
    func finishAcceptance(_ attempt: Attempt, failure: Failure? = nil) throws -> Bool {
        guard inFlight == attempt else { throw Error.invalidState }
        defer { inFlight = nil }
        guard let index = entries.firstIndex(where: { $0.id == attempt.entryID }),
              entries[index].session == attempt.session,
              entries[index].sharedStoreIdentifier == attempt.sharedStoreIdentifier else { throw Error.accountMismatch }
        var updated = entries
        updated[index].state = failure.map(State.failed) ?? .loading
        if failure == nil { updated[index].requiresNativeAcceptance = false }
        do { try commit(updated) }
        catch {
            // The native request has finished, but its outcome could not be journaled.
            // Keep an explicit retry path; disk still has .joining for restart recovery.
            entries[index].state = .failed(.interrupted)
            throw error
        }
        return isCurrent(attempt)
    }

    func beginImportResolution(id: UUID, sharedStoreIdentifier: String) throws -> Attempt {
        let entry = entries[try currentIndex(id)]
        guard entry.state == .loading else { throw Error.invalidState }
        return try makeAttempt(entry, store: sharedStoreIdentifier)
    }

    @discardableResult
    func markReady(_ attempt: Attempt, graph: HomeGraphIdentity) throws -> Bool {
        guard isCurrent(attempt) else { return false }
        let index = try currentIndex(attempt.entryID)
        guard entries[index].state == .loading else { throw Error.invalidState }
        guard graph.storeIdentifier == attempt.sharedStoreIdentifier,
              entries[index].sharedStoreIdentifier == graph.storeIdentifier else { throw Error.storeChanged }
        var updated = entries
        updated[index].state = .ready(graph)
        try commit(updated)
        return true
    }

    func retry(id: UUID) throws {
        let index: Int
        if currentSession == nil {
            guard let unbound = entries.firstIndex(where: { $0.id == id && $0.session == nil }) else {
                throw Error.accountMismatch
            }
            index = unbound
        } else { index = try currentIndex(id) }
        guard inFlight?.entryID != id else { throw Error.busy }
        guard case .failed = entries[index].state else { throw Error.invalidState }
        var updated = entries
        updated[index].state = .queued
        updated[index].dismissalRequested = false
        updated[index].openRequested = true
        try commit(updated)
    }

    func requestOpen(id: UUID) throws {
        let index: Int
        if currentSession == nil {
            guard let unbound = entries.firstIndex(where: { $0.id == id && $0.session == nil }) else {
                throw Error.accountMismatch
            }
            index = unbound
        } else { index = try currentIndex(id) }
        guard !entries[index].activationResolved, entries[index].state != .dismissed else {
            throw Error.invalidState
        }
        var updated = entries
        updated[index].openRequested = true
        updated[index].dismissalRequested = false
        try commit(updated)
    }

    func deferOpen(id: UUID, expectedSession: ShopperSession? = nil) throws {
        let index: Int
        if currentSession == nil, let expectedSession {
            guard expectedSession.isWellFormed,
                  expectedSession.containerIdentifier == containerIdentifier,
                  expectedSession.environment == environment,
                  let matching = entries.firstIndex(where: { $0.id == id && $0.session == expectedSession }) else {
                throw Error.accountMismatch
            }
            index = matching
        } else if currentSession == nil {
            guard let unbound = entries.firstIndex(where: { $0.id == id && $0.session == nil }) else {
                throw Error.accountMismatch
            }
            index = unbound
        } else { index = try currentIndex(id) }
        guard !entries[index].activationResolved else { return }
        var updated = entries
        updated[index].openRequested = false
        try commit(updated)
    }

    func dismiss(id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              (entries[index].session == nil && currentSession == nil)
                || (currentSession != nil && entries[index].session == currentSession) else {
            throw Error.accountMismatch
        }
        var updated = entries
        updated[index].dismissalRequested = true
        updated[index].openRequested = false
        // Keep receiving callbacks/imports after dismissal. A UI action cannot cancel
        // the server operation or remove its automatic-selection hold.
        if !updated[index].acceptanceAttempted { updated[index].state = .dismissed }
        try commit(updated)
    }

    /// Resolve only after explicitly opening the invited home or choosing to keep the current home.
    func resolveActivation(id: UUID) throws {
        let index = try currentIndex(id)
        guard case .ready = entries[index].state else { throw Error.invalidState }
        var updated = entries
        updated[index].activationResolved = true
        updated[index].openRequested = false
        try commit(updated)
    }

    private func currentIndex(_ id: UUID) throws -> Int {
        guard let currentSession else { throw Error.accountRequired }
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].session == currentSession else { throw Error.accountMismatch }
        return index
    }

    private static func reopen(_ entry: inout Entry, metadataArchive: Data,
                               displayName: String?, participantPending: Bool) {
        if let displayName { entry.displayName = displayName }
        entry.dismissalRequested = false
        entry.openRequested = true
        entry.participantPending = participantPending
        switch entry.state {
        case .queued, .failed, .dismissed:
            // A replacement one-time link can have the same share identity. Preserve
            // the durable account/entry, but allow that new capability to recover a failure.
            entry.metadataArchive = metadataArchive
            entry.state = .queued
        case .joining:
            // The active Attempt keeps its original immutable capability. If it fails,
            // explicit retry must use the most recently delivered invitation instead.
            entry.metadataArchive = metadataArchive
        case .loading where participantPending, .ready where participantPending:
            // Accepted-before-import and already-imported homes both need the fresh
            // grant accepted; a local share is not proof that renewed access is active.
            entry.metadataArchive = metadataArchive
            entry.state = .queued
            entry.activationResolved = false
            entry.requiresNativeAcceptance = true
        case .loading, .ready: break
        }
    }

    private func makeAttempt(_ entry: Entry, store: String) throws -> Attempt {
        guard let session = currentSession, entry.session == session else { throw Error.accountRequired }
        guard !store.isEmpty, entry.sharedStoreIdentifier == nil || entry.sharedStoreIdentifier == store else {
            throw Error.storeChanged
        }
        return Attempt(id: UUID(), entryID: entry.id, identity: entry.identity, metadataArchive: entry.metadataArchive,
            session: session, sharedStoreIdentifier: store,
            requiresNativeAcceptance: entry.requiresNativeAcceptance, generation: generation)
    }

    private func isCurrent(_ attempt: Attempt) -> Bool {
        generation == attempt.generation && currentSession == attempt.session
    }

    private func commit(_ updated: [Entry]) throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        var options: Data.WritingOptions = .atomic
        #if os(iOS) || os(watchOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(Journal(entries: updated)).write(to: url, options: options)
        entries = updated
    }
}
