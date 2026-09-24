#if DEBUG
import CoreData
import Foundation

/// Opt-in simulator UI fixture. Every test owns an isolated SQLite directory across relaunches.
@MainActor
enum WatchPersistentTestFixture {
    private final class FixturePermissionPolicy: PersistencePermissionPolicy {
        var denySharedWrites = false
        func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {
            guard denySharedWrites else { return }
            let changes = context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects)
            if changes.contains(where: { $0 is HouseholdCartRecord }) {
                throw PersistencePermissionError.updateDenied
            }
        }
    }

    private struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    static func makeIfRequested() throws -> (any WatchShoppingService)? {
        let environment = ProcessInfo.processInfo.environment
        guard let scenario = environment["SHOPPING_WATCH_DURABLE_FIXTURE"] else { return nil }
        guard let rawID = environment["SHOPPING_WATCH_TEST_ID"], let id = UUID(uuidString: rawID) else {
            throw CocoaError(.coderInvalidValue)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchPersistentUITests", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        if scenario == "cleanup" {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            return UnavailableWatchShoppingService()
        }
        guard ["ready", "empty", "setup", "missing", "revoked"].contains(scenario) else {
            throw CocoaError(.coderInvalidValue)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let policy = FixturePermissionPolicy()
        let persistence = try PersistenceController(configuration: .local(storeURL: directory.appendingPathComponent("Shopping.sqlite")),
            permissionPolicy: policy)
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.watch-tests", environment: "Development", accountRecordName: "fixture-alice"))
        let marker = directory.appendingPathComponent("seeded")
        if !FileManager.default.fileExists(atPath: marker.path) {
            if scenario != "setup" { try seed(persistence, provider: provider, scenario: scenario) }
            try Data().write(to: marker, options: .atomic)
        }
        policy.denySharedWrites = scenario == "revoked"
        let writable: (@MainActor (UUID) -> Bool)?
        if scenario == "revoked" { writable = { _ in false } } else { writable = nil }
        return PersistentWatchShoppingService(persistence: persistence, sessionProvider: provider,
            selectionURL: directory.appendingPathComponent("selection.json"),
            householdWritable: writable)
    }

    private static func seed(_ persistence: PersistenceController, provider: FixedSession, scenario: String) throws {
        let context = persistence.container.viewContext
        let householdID = UUID(), listID = UUID()
        var needIDs: [UUID] = []
        try context.performAndWait {
            let household = Household(context: context)
            household.id = householdID
            household.name = "Watch test household"
            let list = GroceryList(context: context)
            list.id = listID
            list.household = household
            let store = Store(context: context)
            store.id = UUID()
            store.name = "Market"
            store.household = household
            let category = Category(context: context)
            category.id = UUID()
            category.name = "Groceries"
            category.household = household
            if scenario != "empty" {
                for name in scenario == "ready" ? ["Milk"] : ["Milk", "Bread"] {
                    let item = Item(context: context)
                    item.id = UUID()
                    item.name = name
                    item.notes = ""
                    item.anyStore = true
                    item.household = household
                    item.category = category
                    let need = Need(context: context)
                    need.id = UUID()
                    need.kind = NeedKind.remembered.rawValue
                    need.title = name
                    need.notes = ""
                    need.urgency = NeedUrgency.normal.rawValue
                    need.item = item
                    need.list = list
                    needIDs.append(need.id)
                }
            }
            try persistence.prepareForSave(context)
            try context.save()
        }
        if scenario == "missing" || scenario == "revoked" {
            let cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
            for needID in needIDs { try cart.cart(needID: needID, householdID: householdID, listID: listID) }
            let entries = try cart.entries(householdID: householdID, listID: listID)
            let bread = entries.filter { $0.token.needID == needIDs[1] }
            _ = try cart.checkout(cart.prepareCheckout(tokens: bread.map(\.token)))
            if scenario == "missing" {
                try context.performAndWait {
                    let request = Household.fetchRequest()
                    for household in try context.fetch(request) { context.delete(household) }
                    try persistence.prepareForSave(context)
                    try context.save()
                }
            }
        }
    }
}
#endif
