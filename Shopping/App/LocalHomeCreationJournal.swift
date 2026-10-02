import Foundation

struct LocalHomeCreationCommand: Codable, Equatable, Sendable {
    let id: UUID
    let storeIdentifier: String
    let householdID: UUID
    let listID: UUID
    let name: String
}

/// Exact first-home IDs survive a save that completes before the UI can observe it.
final class LocalHomeCreationJournal: @unchecked Sendable {
    enum Failure: Error { case storeChanged }

    private static let lock = NSLock()
    private let url: URL

    init(storeURL: URL) {
        url = storeURL.deletingLastPathComponent().appendingPathComponent(
            storeURL.lastPathComponent + "-first-home.json")
    }

    func pending(storeIdentifier: String) throws -> LocalHomeCreationCommand? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try load(storeIdentifier: storeIdentifier)
    }

    func begin(name: String, storeIdentifier: String) throws -> LocalHomeCreationCommand {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let pending = try load(storeIdentifier: storeIdentifier) { return pending }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NeedServiceError.invalidName }
        let command = LocalHomeCreationCommand(id: UUID(), storeIdentifier: storeIdentifier,
            householdID: UUID(), listID: UUID(), name: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(command).write(to: url, options: .atomic)
        return command
    }

    func acknowledge(_ command: LocalHomeCreationCommand) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try load(storeIdentifier: command.storeIdentifier) == command else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func load(storeIdentifier: String) throws -> LocalHomeCreationCommand? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let command = try JSONDecoder().decode(LocalHomeCreationCommand.self, from: Data(contentsOf: url))
        guard command.storeIdentifier == storeIdentifier else { throw Failure.storeChanged }
        return command
    }
}
