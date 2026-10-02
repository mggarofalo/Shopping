import Foundation

/// A selected retained home's explicit copy intent. The snapshot and destination
/// identities are durable before an account store is opened or changed.
struct RetainedHomeConversion: Codable, Equatable, Sendable {
    struct Named: Codable, Equatable, Sendable {
        let sourceID: UUID
        let id: UUID
        let name: String
        let order: Int64
        let archived: Bool
        let revision: Int64
    }

    struct ItemValue: Codable, Equatable, Sendable {
        let sourceID: UUID
        let id: UUID
        let name: String
        let notes: String
        let anyStore: Bool
        let archived: Bool
        let revision: Int64
        let categoryID: UUID?
        let storeIDs: [UUID]
    }

    struct NeedValue: Codable, Equatable, Sendable {
        let sourceID: UUID
        let id: UUID
        let kind: String
        let title: String
        let notes: String
        let quantity: Int64?
        let urgency: String
        let revision: Int64
        let oneTimeAnyStore: Bool
        let itemID: UUID?
        let categoryID: UUID?
        let storeIDs: [UUID]
        let personID: UUID?
    }

    struct Graph: Codable, Equatable, Sendable {
        let householdID: UUID
        let listID: UUID
        let name: String
        let stores: [Named]
        let categories: [Named]
        let people: [Named]
        let items: [ItemValue]
        let needs: [NeedValue]
    }

    let id: UUID
    let session: ShopperSession
    // Nil identifies an explicit selected local graph, independent of the
    // immutable account-adoption decision for an earlier graph in this store.
    let retainedRecordID: UUID?
    let sourceURL: URL
    let sourceStoreIdentifier: String
    let sourceGraph: HomeGraphIdentity
    let graph: Graph
    var targetStoreIdentifier: String?
    var copied: Bool
}

final class RetainedHomeConversionJournal: @unchecked Sendable {
    enum Failure: LocalizedError {
        case sourceChanged
        case accountChanged
        case incompleteCopy

        var errorDescription: String? {
            switch self {
            case .sourceChanged: return "This device’s home changed. Open it and try again."
            case .accountChanged: return "The iCloud account changed. Check your homes before continuing."
            case .incompleteCopy: return "The saved copy needs recovery. Your original home is safe."
            }
        }
    }

    private static let lock = NSLock()
    private let url: URL
    private struct History: Codable {
        let version: Int
        var commands: [RetainedHomeConversion]
        var deletedCommandIDs: Set<UUID>
    }

    init(baseDirectory: URL, session: ShopperSession) {
        url = baseDirectory.appendingPathComponent("retained-home-conversion-"
            + ActiveHomeScope.accountNamespace(session) + ".json")
    }

    func read(session: ShopperSession) throws -> RetainedHomeConversion? {
        try Self.lock.withLock { try load(session: session).commands.last }
    }

    func read(session: ShopperSession, id: UUID) throws -> RetainedHomeConversion? {
        try Self.lock.withLock { try load(session: session).commands.first { $0.id == id } }
    }

    func read(session: ShopperSession, source: HomeGraphIdentity,
              retainedRecordID: UUID?) throws -> RetainedHomeConversion? {
        try Self.lock.withLock {
            try load(session: session).commands.last {
                $0.sourceGraph == source && $0.retainedRecordID == retainedRecordID
            }
        }
    }

    func read(session: ShopperSession, retainedRecordID: UUID) throws -> RetainedHomeConversion? {
        try Self.lock.withLock {
            try load(session: session).commands.last { $0.retainedRecordID == retainedRecordID }
        }
    }

    func wasDestinationDeleted(_ command: RetainedHomeConversion) throws -> Bool {
        try Self.lock.withLock {
            let history = try load(session: command.session)
            guard history.commands.contains(where: { $0.id == command.id }) else { throw Failure.accountChanged }
            return history.deletedCommandIDs.contains(command.id)
        }
    }

    /// Call only after the private deletion ledger confirms completion for this
    /// account and exact destination. The old copy command stays in history.
    func noteCompletedDeletion(session: ShopperSession, storeIdentifier: String,
                               householdID: UUID, listID: UUID) throws {
        try Self.lock.withLock {
            var history = try load(session: session)
            guard let command = history.commands.last(where: {
                $0.targetStoreIdentifier == storeIdentifier
                    && $0.graph.householdID == householdID && $0.graph.listID == listID
            }) else { return }
            guard history.deletedCommandIDs.insert(command.id).inserted else { return }
            try save(history)
        }
    }

    func begin(_ proposed: RetainedHomeConversion) throws -> RetainedHomeConversion {
        try Self.lock.withLock {
            var history = try load(session: proposed.session)
            if let saved = history.commands.last(where: {
                $0.retainedRecordID == proposed.retainedRecordID
                    && $0.sourceURL == proposed.sourceURL
                    && $0.sourceStoreIdentifier == proposed.sourceStoreIdentifier
                    && $0.sourceGraph == proposed.sourceGraph
            }) {
                if !history.deletedCommandIDs.contains(saved.id) { return saved }
            }
            history.commands.append(proposed)
            try save(history)
            return proposed
        }
    }

    func bind(_ command: RetainedHomeConversion, to storeIdentifier: String) throws -> RetainedHomeConversion {
        try Self.lock.withLock {
            var history = try load(session: command.session)
            guard let index = history.commands.firstIndex(where: { $0.id == command.id }) else {
                throw Failure.accountChanged
            }
            var saved = history.commands[index]
            guard
                  !history.deletedCommandIDs.contains(command.id) else {
                throw Failure.accountChanged
            }
            if let bound = saved.targetStoreIdentifier {
                guard bound == storeIdentifier else { throw Failure.accountChanged }
            } else {
                saved.targetStoreIdentifier = storeIdentifier
                history.commands[index] = saved
                try save(history)
            }
            return saved
        }
    }

    func markCopied(_ command: RetainedHomeConversion) throws {
        try Self.lock.withLock {
            var history = try load(session: command.session)
            guard let index = history.commands.firstIndex(where: { $0.id == command.id }) else {
                throw Failure.accountChanged
            }
            var saved = history.commands[index]
            guard !history.deletedCommandIDs.contains(command.id),
                  saved.targetStoreIdentifier == command.targetStoreIdentifier,
                  saved.targetStoreIdentifier != nil else { throw Failure.accountChanged }
            guard !saved.copied else { return }
            saved.copied = true
            history.commands[index] = saved
            try save(history)
        }
    }

    private func load(session: ShopperSession) throws -> History {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return History(version: 1, commands: [], deletedCommandIDs: [])
        }
        let history = try JSONDecoder().decode(History.self, from: Data(contentsOf: url))
        guard history.version == 1,
              Set(history.commands.map(\.id)).count == history.commands.count,
              history.deletedCommandIDs.isSubset(of: Set(history.commands.map(\.id))),
              history.commands.allSatisfy({ saved in
                  saved.session == session && saved.session.isWellFormed && saved.sourceURL.isFileURL
                      && saved.sourceGraph.storeIdentifier == saved.sourceStoreIdentifier
                      && saved.sourceGraph.householdID != PersistenceModel.unsetID
                      && saved.sourceGraph.listID != PersistenceModel.unsetID
              }) else { throw Failure.accountChanged }
        return history
    }

    private func save(_ history: History) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: url, options: .atomic)
    }
}
