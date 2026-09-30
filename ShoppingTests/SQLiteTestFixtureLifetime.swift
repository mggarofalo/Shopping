import CoreData
import XCTest
@testable import Shopping

/// Owns disk fixtures until their synchronous services and every registered context are finished.
/// Tests with asynchronous workers must await those workers before this teardown runs.
final class SQLiteTestFixtureLifetime {
    private enum CleanupError: Error {
        case storesStillAttached
    }

    private var directories: [URL] = []
    private var controllers: [PersistenceController] = []
    private var contexts: [NSManagedObjectContext] = []

    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    @discardableResult
    func own(_ controller: PersistenceController) -> PersistenceController {
        if !controllers.contains(where: { $0 === controller }) {
            controllers.append(controller)
        }
        return controller
    }

    @discardableResult
    func own(_ context: NSManagedObjectContext) -> NSManagedObjectContext {
        if !contexts.contains(where: { $0 === context }) {
            contexts.append(context)
        }
        return context
    }

    func cleanup() throws {
        // Drain all writers before resetting readers, including queued automatic view merges.
        for controller in controllers {
            reset(controller.writer)
        }
        for context in contexts {
            reset(context)
        }
        for controller in controllers {
            reset(controller.container.viewContext)
        }
        // Reopened controllers may share a file. Detach every coordinator before any deletion.
        for controller in controllers {
            let coordinator = controller.container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try coordinator.remove(store)
            }
            XCTAssertTrue(coordinator.persistentStores.isEmpty)
            guard coordinator.persistentStores.isEmpty else {
                throw CleanupError.storesStillAttached
            }
        }
        for directory in directories {
            try FileManager.default.removeItem(at: directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        contexts.removeAll()
        controllers.removeAll()
        directories.removeAll()
    }

    private func reset(_ context: NSManagedObjectContext) {
        context.performAndWait {
            context.automaticallyMergesChangesFromParent = false
            context.reset()
            XCTAssertTrue(context.registeredObjects.isEmpty)
            XCTAssertFalse(context.hasChanges)
        }
    }
}
