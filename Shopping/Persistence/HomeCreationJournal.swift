import Foundation

struct HomeCreationCommand: Codable, Equatable, Sendable {
    let id: UUID
    let session: ShopperSession
    let storeIdentifier: String
    let householdID: UUID
    let listID: UUID
    let name: String
}

/// Local intent survives termination before or after the atomic household/list save.
/// It is acknowledged only once its result reaches the initiating UI.
final class HomeCreationJournal: @unchecked Sendable {
    enum Failure: LocalizedError {
        case staleResume
        var errorDescription: String? {
            "This creation request has already finished or changed. Check Your homes before creating another."
        }
    }
    private static let lock = NSLock()
    private let url: URL

    init(url: URL) { self.url = url }

    static func location(storeURL: URL, session: ShopperSession) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(
            "home-creation-" + ActiveHomeScope.accountNamespace(session) + ".json")
    }

    func pending(session: ShopperSession, storeIdentifier: String) throws -> HomeCreationCommand? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try load(session: session, storeIdentifier: storeIdentifier)
    }

    func begin(name: String, session: ShopperSession, storeIdentifier: String,
               resuming expected: HomeCreationCommand? = nil) throws -> HomeCreationCommand {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let pending = try load(session: session, storeIdentifier: storeIdentifier)
        if let expected {
            guard pending == expected else { throw Failure.staleResume }
            return expected
        }
        if let pending { return pending }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NeedServiceError.invalidName }
        let command = HomeCreationCommand(id: UUID(), session: session, storeIdentifier: storeIdentifier,
            householdID: UUID(), listID: UUID(), name: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(command).write(to: url, options: .atomic)
        return command
    }

    func acknowledge(_ command: HomeCreationCommand) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try load(session: command.session, storeIdentifier: command.storeIdentifier) == command else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func load(session: ShopperSession, storeIdentifier: String) throws -> HomeCreationCommand? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let command = try JSONDecoder().decode(HomeCreationCommand.self, from: Data(contentsOf: url))
        guard command.session == session, command.storeIdentifier == storeIdentifier else {
            throw ShopperSessionError.accountChanged
        }
        return command
    }
}
