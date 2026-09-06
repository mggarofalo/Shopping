import CoreData
@testable import Shopping

/// A deterministic local Core Data simulation. It does not model transport or prove CloudKit convergence.
final class LocalTwoContextHarness {
    enum Replica { case first, second }
    enum SaveOrder { case firstThenSecond, secondThenFirst }

    let persistence: PersistenceController
    let first: NSManagedObjectContext
    let second: NSManagedObjectContext

    init(storeURL: URL) throws {
        persistence = try PersistenceController(storeURL: storeURL)
        first = persistence.simulationContext()
        second = persistence.simulationContext()
        first.automaticallyMergesChangesFromParent = false
        second.automaticallyMergesChangesFromParent = false
    }

    func stage(_ replica: Replica, _ changes: (NSManagedObjectContext) throws -> Void) throws {
        let context = replica == .first ? first : second
        try context.performAndWait { try changes(context) }
    }

    func save(in order: SaveOrder) throws {
        switch order {
        case .firstThenSecond:
            try save(first)
            try save(second)
        case .secondThenFirst:
            try save(second)
            try save(first)
        }
    }

    func reset(_ replica: Replica) {
        let context = replica == .first ? first : second
        context.performAndWait { context.reset() }
    }

    private func save(_ context: NSManagedObjectContext) throws {
        try context.performAndWait {
            if context.hasChanges { try context.save() }
        }
    }
}
