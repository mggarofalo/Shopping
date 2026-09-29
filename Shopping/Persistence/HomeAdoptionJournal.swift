import CoreData
import Foundation

/// Worker-only, durable approval and verification around the existing V7 cart migration.
/// It never combines graphs, assigns cart ownership, or removes the local source.
final class HomeAdoptionJournal: @unchecked Sendable {
    enum Action: String, Codable, Sendable { case copy, keepLocal }
    enum Checkpoint { case approved, snapshotSaved, copyReturned, verified }
    enum Failure: Error, LocalizedError {
        case staleProposal, invalidJournal, sourceChanged, copyUnavailable
        var errorDescription: String? {
            switch self {
            case .staleProposal: return "Home setup has changed. Check your homes before continuing."
            case .invalidJournal: return "Saved home setup could not be verified. Your groceries have been retained."
            case .sourceChanged: return "The original home could not be identified. Your groceries have not been replaced."
            case .copyUnavailable: return "This account already has saved groceries. Keep this device’s home separately."
            }
        }
    }

    struct Proposal: Codable, Equatable, Sendable {
        let sourceURL: URL?
        let sourceStoreIdentifier: String?
        let session: ShopperSession
        let householdID: UUID?
        let listID: UUID?
        let homeName: String
        let canCopy: Bool
    }

    struct Record: Codable, Equatable, Sendable {
        let id: UUID
        let proposal: Proposal
        let action: Action
        var verified: Bool
        var snapshot: HomeAdoptionSnapshot?
        var sourceURL: URL? { proposal.sourceURL }
        var homeName: String { proposal.homeName }
        var householdID: UUID? { proposal.householdID }
        var listID: UUID? { proposal.listID }
        var session: ShopperSession { proposal.session }
    }

    struct ActivationResult: Sendable {
        let configuration: PersistenceConfiguration
        let retainedLocal: Record?
        let preferredHouseholdID: UUID?
        let preferredListID: UUID?
    }

    private struct Envelope: Codable {
        let version: Int
        var record: Record
    }
    private static let lock = NSLock()
    private let baseDirectory: URL
    private var url: URL { baseDirectory.appendingPathComponent("HomeAdoption.json") }

    init(baseDirectory: URL) { self.baseDirectory = baseDirectory }

    func prepare(sourceURL: URL?, session: ShopperSession, householdID: UUID?, listID: UUID?,
                 homeName: String) throws -> Proposal {
        try Self.lock.withLock {
            guard session.isWellFormed else { throw ShopperSessionError.invalidIdentity }
            if let saved = try load() {
                if saved.session == session {
                    // Reconnecting an already configured account needs no new copy decision.
                    if saved.verified, sourceURL == nil {
                        return Proposal(sourceURL: nil, sourceStoreIdentifier: nil, session: session,
                            householdID: nil, listID: nil, homeName: homeName, canCopy: false)
                    }
                    // Completed setup is not a new permission to copy a diverged backup.
                    if sourceURL == nil || sourceURL.map(Self.canonical) == saved.sourceURL { return saved.proposal }
                    throw Failure.staleProposal
                }
                if !saved.verified { throw ShopperSessionError.accountChanged }
                if sourceURL != nil { throw ShopperSessionError.accountChanged }
            }
            let source = sourceURL.map(Self.canonical)
            let identifier = try source.map(Self.sourceIdentifier)
            let directory = try session.storeDirectory(in: baseDirectory)
            let canCopy = source != nil && !Self.storeExists(directory.appendingPathComponent("Private.sqlite"))
                && !Self.storeExists(directory.appendingPathComponent("Shared.sqlite"))
            return Proposal(sourceURL: source, sourceStoreIdentifier: identifier, session: session,
                householdID: householdID, listID: listID, homeName: homeName, canCopy: canCopy)
        }
    }

    @discardableResult
    func approve(_ proposal: Proposal, action: Action,
                 checkpoint: (Checkpoint) throws -> Void = { _ in }) throws -> Record {
        try Self.lock.withLock {
            guard proposal.session.isWellFormed else { throw ShopperSessionError.invalidIdentity }
            if let saved = try load() {
                guard saved.proposal == proposal, saved.action == action else { throw Failure.staleProposal }
                return saved
            }
            if let source = proposal.sourceURL {
                guard try Self.sourceIdentifier(source) == proposal.sourceStoreIdentifier else { throw Failure.sourceChanged }
            } else if action == .copy { throw Failure.copyUnavailable }
            if action == .copy {
                let directory = try proposal.session.storeDirectory(in: baseDirectory)
                guard proposal.canCopy, !Self.storeExists(directory.appendingPathComponent("Private.sqlite")),
                      !Self.storeExists(directory.appendingPathComponent("Shared.sqlite")) else { throw Failure.copyUnavailable }
            }
            let record = Record(id: UUID(), proposal: proposal, action: action, verified: false, snapshot: nil)
            try save(record)
            try checkpoint(.approved)
            return record
        }
    }

    /// Only the explicitly retained device-local route may be restored offline.
    /// This record never authorizes opening account stores or assigning a cart.
    func retainedLocalRecord() throws -> Record? {
        try Self.lock.withLock {
            guard let record = try load(), record.verified, record.action == .keepLocal,
                  record.sourceURL != nil else { return nil }
            return record
        }
    }

    func record(session: ShopperSession) throws -> Record? {
        try Self.lock.withLock {
            guard let record = try load() else { return nil }
            guard record.session == session else {
                if !record.verified { throw ShopperSessionError.accountChanged }
                return nil
            }
            return record
        }
    }

    /// Source must be detached before entering. A persisted snapshot gates every retry
    /// until verification succeeds. Subsequent account edits are never compared to a backup.
    func activate(session: ShopperSession,
                  using activate: @Sendable (URL?, ShopperSession, URL, Bool) throws -> PersistenceConfiguration,
                  checkpoint: (Checkpoint) throws -> Void = { _ in }) throws -> ActivationResult {
        try Self.lock.withLock {
            guard var record = try load() else {
                return ActivationResult(configuration: try activate(nil, session, baseDirectory, false),
                    retainedLocal: nil, preferredHouseholdID: nil, preferredListID: nil)
            }
            guard record.session == session else {
                guard record.verified else { throw ShopperSessionError.accountChanged }
                return ActivationResult(configuration: try activate(nil, session, baseDirectory, false),
                    retainedLocal: nil, preferredHouseholdID: nil, preferredListID: nil)
            }
            if record.action == .copy && !record.verified {
                try validateSource(record)
                guard let source = record.sourceURL else { throw Failure.sourceChanged }
                if record.snapshot == nil {
                    record.snapshot = try HomeAdoptionSnapshot.capture(at: source)
                    try save(record)
                    try checkpoint(.snapshotSaved)
                }
            }
            let configuration = try activate(record.action == .copy ? record.sourceURL : nil,
                session, baseDirectory, record.action == .copy)
            try checkpoint(.copyReturned)
            if !record.verified {
                if record.action == .copy {
                    guard let expected = record.snapshot,
                          let destination = configuration.stores.first(where: { $0.role == .ownerPrivate })?.url else {
                        throw Failure.invalidJournal
                    }
                    try HomeAdoptionSnapshot.capture(at: destination).verify(matches: expected)
                }
                record.verified = true
                record.snapshot = nil
                try save(record)
                try checkpoint(.verified)
            }
            return ActivationResult(configuration: configuration,
                retainedLocal: record.action == .keepLocal && record.sourceURL != nil ? record : nil,
                preferredHouseholdID: record.action == .copy ? record.householdID : nil,
                preferredListID: record.action == .copy ? record.listID : nil)
        }
    }

    func validateRetainedSource(_ record: Record) throws {
        try Self.lock.withLock {
            guard let saved = try load(), saved.id == record.id, saved.action == .keepLocal else { throw Failure.staleProposal }
            try validateSource(saved)
        }
    }

    private func validateSource(_ record: Record) throws {
        guard let source = record.sourceURL,
              try Self.sourceIdentifier(source) == record.proposal.sourceStoreIdentifier else { throw Failure.sourceChanged }
    }

    private func load() throws -> Record? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 1, envelope.record.session.isWellFormed,
              (envelope.record.sourceURL == nil) == (envelope.record.proposal.sourceStoreIdentifier == nil),
              envelope.record.action != .copy || envelope.record.sourceURL != nil else { throw Failure.invalidJournal }
        return envelope.record
    }

    private func save(_ record: Record) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Envelope(version: 1, record: record)).write(to: url, options: .atomic)
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static func sourceIdentifier(_ url: URL) throws -> String {
        guard url.isFileURL, storeExists(url) else { throw Failure.sourceChanged }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
            at: url, options: [NSReadOnlyPersistentStoreOption: true])
        guard let identifier = metadata[NSStoreUUIDKey] as? String, UUID(uuidString: identifier) != nil else {
            throw Failure.sourceChanged
        }
        return identifier
    }
    private static func storeExists(_ url: URL) -> Bool {
        ["", "-wal", "-shm"].contains { FileManager.default.fileExists(atPath: url.path + $0) }
    }
}
