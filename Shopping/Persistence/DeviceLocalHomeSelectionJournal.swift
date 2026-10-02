import CoreData
import Foundation

/// One current device-local route; the conversion journal owns copy history.
final class DeviceLocalHomeSelectionJournal: @unchecked Sendable {
    enum Failure: Error { case invalidSelection }

    private static let lock = NSLock()
    private let url: URL

    init(baseDirectory: URL) {
        url = baseDirectory.appendingPathComponent("DeviceLocalHomeSelection.json")
    }

    func read() throws -> DeviceLocalHomeSelection? {
        try Self.lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let source = try JSONDecoder().decode(DeviceLocalHomeSelection.self, from: Data(contentsOf: url))
            try validate(source)
            let deletions = try LocalHomeDeletionJournal(storeURL: source.sourceURL).statuses()
                .filter { $0.command.graph == source.graph }
            if deletions.contains(where: { $0.completed }) { return nil }
            if deletions.isEmpty { try validateGraph(source) }
            return source
        }
    }

    func select(_ source: DeviceLocalHomeSelection) throws {
        try Self.lock.withLock {
            try validate(source)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(source).write(to: url, options: .atomic)
        }
    }

    private func validate(_ source: DeviceLocalHomeSelection) throws {
        guard source.session.isWellFormed, source.sourceURL.isFileURL,
              source.graph.householdID != PersistenceModel.unsetID,
              source.graph.listID != PersistenceModel.unsetID,
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: source.sourceURL,
                options: [NSReadOnlyPersistentStoreOption: true]),
              metadata[NSStoreUUIDKey] as? String == source.graph.storeIdentifier else {
            throw Failure.invalidSelection
        }
        if let id = source.conversionID {
            let journal = RetainedHomeConversionJournal(baseDirectory: url.deletingLastPathComponent(),
                session: source.session)
            guard let command = try journal.read(session: source.session, id: id),
                  command.sourceURL == source.sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
                  command.sourceGraph == source.graph else { throw Failure.invalidSelection }
        }
    }

    private func validateGraph(_ source: DeviceLocalHomeSelection) throws {
        let persistence = try PersistenceController(storeURL: source.sourceURL)
        defer {
            persistence.writer.performAndWait { persistence.writer.reset() }
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try? persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        guard try HomeDiscoveryService(persistence: persistence).discover().homes.contains(where: {
            $0.graph == source.graph
        }) else { throw Failure.invalidSelection }
    }
}
