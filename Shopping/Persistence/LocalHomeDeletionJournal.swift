import Foundation

/// The marker stays outside the deleted graph and never changes the adoption decision.
final class LocalHomeDeletionJournal: @unchecked Sendable {
    private struct Record: Codable { let command: HomeDeletionCommand; var completed: Bool }
    private static let lock = NSLock()
    let storeURL: URL
    init(storeURL: URL) { self.storeURL = storeURL.standardizedFileURL }
    private var url: URL { storeURL.appendingPathExtension("home-deletions.json") }

    func statuses() throws -> [HomeDeletionStatus] {
        try Self.lock.withLock { try load().map { HomeDeletionStatus(command: $0.command, submitted: true, completed: $0.completed) } }
    }

    func retain(_ command: HomeDeletionCommand) throws {
        try Self.lock.withLock {
            try command.validate()
            guard command.isLocal, command.storeURL.standardizedFileURL == storeURL else { throw HomeDeletionError.scopeChanged }
            var records = try load()
            if let existing = records.first(where: { $0.command.graph == command.graph }) {
                guard existing.command == command else { throw HomeDeletionError.scopeChanged }
                return
            }
            records.append(Record(command: command, completed: false))
            try save(records)
        }
    }

    func complete(_ command: HomeDeletionCommand) throws {
        try Self.lock.withLock {
            var records = try load()
            guard let index = records.firstIndex(where: { $0.command == command }) else { throw HomeDeletionError.scopeChanged }
            records[index].completed = true
            try save(records)
        }
    }

    func contains(_ graph: HomeGraphIdentity) throws -> Bool {
        try contains(storeIdentifier: graph.storeIdentifier, householdID: graph.householdID, listID: graph.listID)
    }

    func contains(storeIdentifier: String, householdID: UUID, listID: UUID) throws -> Bool {
        try !matching(storeIdentifier: storeIdentifier, householdID: householdID, listID: listID).isEmpty
    }

    func blocksUse(_ graph: HomeGraphIdentity) throws -> Bool {
        try matching(storeIdentifier: graph.storeIdentifier, householdID: graph.householdID,
                     listID: graph.listID).contains(where: \.blocksHomeUse)
    }

    private func matching(storeIdentifier: String, householdID: UUID, listID: UUID) throws -> [HomeDeletionStatus] {
        // Stable identities also fence recreation under a new Core Data object URI.
        try statuses().filter { $0.command.graph.storeIdentifier == storeIdentifier
            && $0.command.graph.householdID == householdID && $0.command.graph.listID == listID }
    }

    /// Caller must prove the exact source root still exists on its writer queue.
    /// A local SQLite delete is atomic, so that proof excludes a committed delete.
    func cancelUncommittedStarter(_ command: HomeDeletionCommand) throws {
        try Self.lock.withLock {
            guard command.starterRequirement != nil else { throw HomeDeletionError.scopeChanged }
            var records = try load()
            guard let index = records.firstIndex(where: { $0.command == command }) else { return }
            guard !records[index].completed else { throw HomeDeletionError.scopeChanged }
            records.remove(at: index)
            try save(records)
        }
    }

    private func load() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        for record in records {
            try record.command.validate()
            guard record.command.isLocal, record.command.storeURL.standardizedFileURL == storeURL else {
                throw PersonalCartError.corruptRecord
            }
        }
        guard Set(records.map { $0.command.id }).count == records.count else { throw PersonalCartError.corruptRecord }
        return records
    }

    private func save(_ records: [Record]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }
}
