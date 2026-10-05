import CoreData
import XCTest
@testable import Shopping

/// Copies application records between isolated SQLite replicas; it does not model CloudKit transport.
final class ReplicaContractFixture {
    struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    private var deliveredPhysicalRecords: [String: Set<String>] = [:]

    let lifetime: SQLiteTestFixtureLifetime
    let persistence: PersistenceController
    let needs: NeedService
    let cart: PersonalCartService
    let householdID: UUID
    let listID: UUID
    let itemID: UUID
    let needID: UUID
    let url: URL

    init(lifetime: SQLiteTestFixtureLifetime) throws {
        self.lifetime = lifetime
        url = try lifetime.makeDirectory().appendingPathComponent("source.sqlite")
        persistence = try lifetime.own(PersistenceController(storeURL: url))
        needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        householdID = scope.householdID
        listID = scope.listID
        itemID = try needs.createItem(name: "Milk", householdID: householdID)
        needID = try needs.addRememberedNeed(itemID: itemID, listID: listID,
            householdID: householdID, quantity: nil)
        cart = PersonalCartService(persistence: persistence, sessionProvider: try Self.session("alice"))
    }

    static func session(_ name: String) throws -> FixedSession {
        FixedSession(session: try ShopperSession.authenticated(containerIdentifier: "iCloud.shopping.tests",
            environment: "Development", accountRecordName: name))
    }

    func copy(shopper: String = "alice") throws -> PersonalCartService {
        let target = try lifetime.makeDirectory().appendingPathComponent("replica.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: persistence.container.managedObjectModel)
        try coordinator.replacePersistentStore(at: target, destinationOptions: nil,
            withPersistentStoreFrom: url, sourceOptions: nil, ofType: NSSQLiteStoreType)
        let controller = try lifetime.own(PersistenceController(storeURL: target))
        return PersonalCartService(persistence: controller, sessionProvider: try Self.session(shopper))
    }

    func reopen(_ service: PersonalCartService, shopper: String = "alice") throws -> PersonalCartService {
        let storeURL = try XCTUnwrap(service.persistence.primaryStore?.url)
        let controller = try lifetime.own(PersistenceController(storeURL: storeURL))
        return PersonalCartService(persistence: controller, sessionProvider: try Self.session(shopper))
    }

    func add(_ service: PersonalCartService? = nil) throws -> PersonalCartEntrySnapshot {
        let service = service ?? cart
        try service.cart(needID: needID, householdID: householdID, listID: listID)
        return try entry(service)
    }

    func entry(_ service: PersonalCartService) throws -> PersonalCartEntrySnapshot {
        let entries = try service.entries(householdID: householdID, listID: listID)
        XCTAssertEqual(entries.count, 1)
        return try XCTUnwrap(entries.first)
    }

    func deliver(_ source: PersonalCartService, to target: PersonalCartService,
                 privateIDs: Set<UUID>? = nil, includePrivate: Bool = true, includeShared: Bool = true) throws {
        let sourcePath = try XCTUnwrap(source.persistence.primaryStore?.url?.path)
        let targetPath = try XCTUnwrap(target.persistence.primaryStore?.url?.path)
        let delivered = deliveredPhysicalRecords[targetPath, default: []]
        let rows = try source.transact(save: false) { repository in
            let privateRows = try repository.privateRecords().filter {
                includePrivate && (privateIDs == nil || privateIDs!.contains($0.id))
            }.map { ($0.id, $0.kind, $0.accountBinding, $0.command, $0.payload,
                "\(sourcePath)|\($0.objectID.uriRepresentation().absoluteString)") }
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            let sharedRows = try repository.context.fetch(request).filter { _ in includeShared }
                .map { ($0.id, $0.kind, $0.payload, $0.household?.id,
                    "\(sourcePath)|\($0.objectID.uriRepresentation().absoluteString)") }
            return (privateRows, sharedRows)
        }
        try target.transact { repository in
            guard rows.0.allSatisfy({ $0.2 == repository.session.accountBinding }) else {
                throw PersonalCartError.accountChanged
            }
            for row in rows.0 where !delivered.contains(row.5) {
                let record = PersonalCartRecord(context: repository.context)
                repository.context.assign(record, to: try XCTUnwrap(repository.persistence.primaryStore))
                record.id = row.0
                record.kind = row.1
                record.accountBinding = row.2
                record.command = row.3
                record.payload = row.4
            }
            for row in rows.1 where !delivered.contains(row.4) {
                let home = try repository.household(XCTUnwrap(row.3))
                let record = HouseholdCartRecord(context: repository.context)
                repository.context.assign(record, to: try XCTUnwrap(home.objectID.persistentStore))
                record.id = row.0
                record.kind = row.1
                record.payload = row.2
                record.household = home
            }
        }
        deliveredPhysicalRecords[targetPath, default: []].formUnion(rows.0.map { $0.5 })
        deliveredPhysicalRecords[targetPath, default: []].formUnion(rows.1.map { $0.4 })
    }

    func recordCounts(_ service: PersonalCartService) throws -> [String: Int] {
        try service.transact(save: false) { repository in
            let privateCount = try repository.context.count(for: NSFetchRequest<PersonalCartRecord>(entityName: "PersonalCartRecord"))
            let sharedCount = try repository.context.count(for: NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord"))
            return ["private": privateCount, "shared": sharedCount]
        }
    }
}
