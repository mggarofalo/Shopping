import CloudKit
import CoreData
import XCTest
@testable import Shopping

final class ImportedNeedReconciliationTests: XCTestCase {
    private let lifetime = SQLiteTestFixtureLifetime()

    override func setUp() {
        super.setUp()
        let lifetime = lifetime
        addTeardownBlock { try lifetime.cleanup() }
    }

    func testImportedPhysicalDuplicateConvergesInBothRecordOrdersAndSurvivesRelaunch() async throws {
        for reverse in [false, true] {
            let fixture = try makeFixture(reverse: reverse)
            XCTAssertThrowsError(try fixture.service.allActiveNeedIDs(householdID: fixture.householdID)) {
                XCTAssertEqual($0 as? NeedServiceError, .invalidOccurrenceIdentity)
            }
            let consumer = PersistentHistoryConsumer(persistence: fixture.persistence,
                checkpoints: FileHistoryCheckpointStore(directory: try lifetime.makeDirectory()),
                needRecordIdentity: { fixture.records[$0] }, needSyncBoundary: { _, _ in .distantFuture })
            _ = try await consumer.consume()
            XCTAssertEqual(try fixture.service.allActiveNeedIDs(householdID: fixture.householdID), [fixture.needID])
            let remaining = try fixture.persistence.writer.performAndWait {
                fixture.persistence.writer.reset()
                return try fixture.persistence.writer.fetch(Need.fetchRequest()).map(\.objectID)
            }
            XCTAssertEqual(remaining.count, 1)
            XCTAssertEqual(remaining.first.flatMap { fixture.records[$0]?.recordName }, "a")
            XCTAssertEqual(try fixture.cart.entries(householdID: fixture.householdID, listID: fixture.listID), [fixture.cartEntry])
            _ = try await consumer.consume()
            let checkout = try fixture.cart.checkout(fixture.cart.prepareCheckout(tokens: [fixture.cartEntry.token]))
            _ = try fixture.cart.restore(checkoutID: checkout.operationID)
            XCTAssertEqual(try fixture.service.allActiveNeedIDs(householdID: fixture.householdID), [fixture.needID])
            let reopened = try lifetime.own(PersistenceController(storeURL: fixture.url))
            XCTAssertEqual(try NeedService(persistence: reopened).allActiveNeedIDs(householdID: fixture.householdID), [fixture.needID])
        }
    }

    func testConflictingFieldsAndRelationshipsRemainUntouched() async throws {
        for key in ["quantity", "revision", "notes", "archived", "clearOperationID", "list", "item"] {
            let fixture = try makeFixture()
            let context = fixture.persistence.writer
            try context.performAndWait {
                context.reset()
                let needs = try context.fetch(Need.fetchRequest())
                let changed = try XCTUnwrap(needs.last)
                switch key {
                case "quantity", "revision": changed.setValue(9, forKey: key)
                case "notes": changed.notes = "Another shopper's edit"
                case "archived": changed.archived = true
                case "clearOperationID": changed.clearOperationID = UUID()
                default: changed.setValue(nil, forKey: key)
                }
                try context.save()
            }
            try await ImportedNeedReconciler(persistence: fixture.persistence,
                recordIdentity: { fixture.records[$0] }, syncBoundary: { _, _ in .distantFuture }).reconcile(in: try XCTUnwrap(fixture.persistence.primaryStore))
            XCTAssertEqual(try count(fixture), 2, key)
        }
    }

    func testMissingCloudIdentityDifferentZonesAndDefaultLocalPolicyDoNotDelete() async throws {
        for mode in ["missing", "same-record", "different-zone", "local"] {
            let fixture = try makeFixture()
            let identity: ImportedNeedReconciler.RecordIdentity? = mode == "local" ? nil : { id in
                guard let record = fixture.records[id] else { return nil }
                if mode == "missing" && record.recordName == "z" { return nil }
                if mode == "same-record" { return CKRecord.ID(recordName: "a", zoneID: record.zoneID) }
                if mode == "different-zone" {
                    return CKRecord.ID(recordName: record.recordName,
                        zoneID: CKRecordZone.ID(zoneName: record.recordName, ownerName: "owner"))
                }
                return record
            }
            try await ImportedNeedReconciler(persistence: fixture.persistence, recordIdentity: identity, syncBoundary: { _, _ in .distantFuture })
                .reconcile(in: try XCTUnwrap(fixture.persistence.primaryStore))
            XCTAssertEqual(try count(fixture), 2, mode)
        }
    }

    func testDeniedRepairRollsBackWithoutBlockingHistoryAndRetriesAfterCheckpoint() async throws {
        let policy = RepairPermission()
        let fixture = try makeFixture(permissionPolicy: policy)
        let checkpoints = FileHistoryCheckpointStore(directory: try lifetime.makeDirectory())
        let consumer = PersistentHistoryConsumer(persistence: fixture.persistence, checkpoints: checkpoints,
            needRecordIdentity: { fixture.records[$0] }, needSyncBoundary: { _, _ in .distantFuture })
        policy.denied = true
        let merged = try await consumer.consume()
        XCTAssertGreaterThan(merged, 0)
        XCTAssertEqual(try count(fixture), 2)
        XCTAssertNotNil(try checkpoints.load(for: try XCTUnwrap(fixture.persistence.primaryStore?.identifier)))
        policy.denied = false
        _ = try await consumer.consume()
        XCTAssertEqual(try count(fixture), 1)
    }

    func testAccountChangeDuringIdentityResolutionRollsBack() async throws {
        let fixture = try makeFixture()
        let provider = ChangingSession(try ReplicaContractFixture.session("alice").session)
        fixture.persistence.personalCartSessionProvider = provider
        let reconciler = ImportedNeedReconciler(persistence: fixture.persistence, recordIdentity: { id in
            provider.session = try! ReplicaContractFixture.session("bob").session
            return fixture.records[id]
        }, syncBoundary: { _, _ in .distantFuture })
        do {
            try await reconciler.reconcile(in: try XCTUnwrap(fixture.persistence.primaryStore))
            XCTFail("Account switch must fail")
        } catch { XCTAssertEqual(error as? PersonalCartError, .accountChanged) }
        XCTAssertEqual(try count(fixture), 2)
    }

    func testSplitImportRetainsLaterRelationshipAndRequiresCompletedSync() async throws {
        let fixture = try makeFixture()
        let store = try XCTUnwrap(fixture.persistence.primaryStore)
        var boundary: Date? = nil
        let reconciler = ImportedNeedReconciler(persistence: fixture.persistence,
            recordIdentity: { fixture.records[$0] }, syncBoundary: { _, _ in boundary })
        try await reconciler.reconcile(in: store)
        XCTAssertEqual(try count(fixture), 2)
        boundary = .distantPast // An earlier successful cycle cannot settle this import.
        try await reconciler.reconcile(in: store)
        XCTAssertEqual(try count(fixture), 2)
        let context = fixture.persistence.writer
        try context.performAndWait {
            context.reset()
            let copies = try context.fetch(Need.fetchRequest())
            let changed = try XCTUnwrap(copies.first { fixture.records[$0.objectID]?.recordName == "z" })
            let person = Person(context: context)
            person.id = UUID()
            person.name = "Imported assignment"
            person.household = changed.list?.household
            changed.person = person
            try context.save()
        }
        boundary = .distantFuture
        try await reconciler.reconcile(in: store)
        XCTAssertEqual(try count(fixture), 2)
        try context.performAndWait {
            context.reset()
            XCTAssertEqual(try context.fetch(Need.fetchRequest()).compactMap { $0.person?.name }, ["Imported assignment"])
        }
    }

    func testSuccessfulSyncRetriesPendingRepairWithoutRefreshingHealthyHistory() async throws {
        let fixture = try makeFixture()
        var boundary: Date? = nil
        let history = PersistentHistoryConsumer(persistence: fixture.persistence,
            checkpoints: FileHistoryCheckpointStore(directory: try lifetime.makeDirectory()),
            needRecordIdentity: { fixture.records[$0] }, needSyncBoundary: { _, _ in boundary })
        _ = try await history.consume()
        XCTAssertEqual(try count(fixture), 2)
        var refreshes = 0
        let observer = PersistentHistoryObserver(persistence: fixture.persistence, history: history, notifications: NotificationCenter()) { refreshes += 1 }
        boundary = .distantFuture
        await observer.successfulSyncCompleted()
        XCTAssertEqual(refreshes, 1)
        _ = try await history.consume()
        XCTAssertEqual(try count(fixture), 1)
        await observer.successfulSyncCompleted()
        XCTAssertEqual(refreshes, 1, "Status-only completions must not refresh healthy groceries")
    }

    func testSyncBoundaryRejectsOverlappingFailedAndUnfinishedCycles() {
        let changed = Date(timeIntervalSince1970: 100)
        func event(_ operation: CloudSyncStatus.Operation, start: Double, end: Double? = 200,
                   failure: CloudSyncStatus.Failure? = nil, store: String = "owner") -> CloudSyncStatus.Event {
            .init(store: store, operation: operation, started: Date(timeIntervalSince1970: start),
                  ended: end.map { Date(timeIntervalSince1970: $0) }, failure: failure)
        }
        var events = [event(.download, start: 90), event(.upload, start: 95)]
        XCTAssertLessThan(ImportedNeedReconciler.settledThrough(events: events, storeIdentifier: "owner")!, changed)
        events += [event(.download, start: 110), event(.upload, start: 120)]
        XCTAssertGreaterThan(ImportedNeedReconciler.settledThrough(events: events, storeIdentifier: "owner")!, changed)
        XCTAssertNil(ImportedNeedReconciler.settledThrough(events: events + [event(.upload, start: 130, end: nil)], storeIdentifier: "owner"))
        XCTAssertNil(ImportedNeedReconciler.settledThrough(events: events + [event(.download, start: 130, failure: .network)], storeIdentifier: "owner"))
        XCTAssertNil(ImportedNeedReconciler.settledThrough(events: [event(.download, start: 110), event(.upload, start: 120, store: "other")], storeIdentifier: "owner"))
    }

    func testCompletionDuringHeldReconciliationIsNotLost() async throws {
        let fixture = try makeFixture()
        let entered = expectation(description: "Writer is checking settlement")
        let release = DispatchSemaphore(value: 0)
        let history = PersistentHistoryConsumer(persistence: fixture.persistence,
            checkpoints: FileHistoryCheckpointStore(directory: try lifetime.makeDirectory()),
            needRecordIdentity: { fixture.records[$0] }, needSyncBoundary: { _, _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
                return nil
            })
        let pass = Task { try await history.consume() }
        await fulfillment(of: [entered], timeout: 5)
        var requested = false
        let observer = PersistentHistoryObserver(persistence: fixture.persistence, history: history,
            notifications: NotificationCenter()) { requested = true }
        await observer.successfulSyncCompleted()
        release.signal()
        _ = try await pass.value
        XCTAssertTrue(requested, "Completion must queue a retry before deferred state returns from the writer")
    }

    private func count(_ fixture: Fixture) throws -> Int {
        try fixture.persistence.writer.performAndWait {
            fixture.persistence.writer.reset()
            return try fixture.persistence.writer.count(for: Need.fetchRequest())
        }
    }

    private final class RepairPermission: PersistencePermissionPolicy {
        var denied = false
        func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {
            if denied && !context.deletedObjects.isEmpty { throw PersistencePermissionError.deleteDenied }
        }
    }

    private final class ChangingSession: ShopperSessionProviding {
        var session: ShopperSession
        init(_ session: ShopperSession) { self.session = session }
        func currentSession() throws -> ShopperSession { session }
    }

    private struct Fixture {
        let persistence: PersistenceController
        let service: NeedService
        let householdID: UUID
        let needID: UUID
        let listID: UUID
        let cart: PersonalCartService
        let cartEntry: PersonalCartEntrySnapshot
        let records: [NSManagedObjectID: CKRecord.ID]
        let url: URL
    }

    private func makeFixture(reverse: Bool = false, permissionPolicy: PersistencePermissionPolicy? = nil) throws -> Fixture {
        let url = try lifetime.makeDirectory().appendingPathComponent("replica.sqlite")
        let persistence = try lifetime.own(PersistenceController(configuration: .local(storeURL: url), permissionPolicy: permissionPolicy))
        let service = NeedService(persistence: persistence)
        let scope = try service.createHousehold()
        let itemID = try service.createItem(name: "Tortilla Chips", householdID: scope.householdID)
        let needID = try service.addRememberedNeed(itemID: itemID, listID: scope.listID, quantity: nil)
        let cart = PersonalCartService(persistence: persistence, sessionProvider: try ReplicaContractFixture.session("alice"))
        try cart.cart(needID: needID, householdID: scope.householdID, listID: scope.listID)
        let cartEntry = try XCTUnwrap(cart.entries(householdID: scope.householdID, listID: scope.listID).first)
        let context = lifetime.own(persistence.simulationContext())
        let records = try context.performAndWait { () -> [NSManagedObjectID: CKRecord.ID] in
            let original = try XCTUnwrap(context.fetch(Need.fetchRequest()).first)
            let imported = Need(context: context)
            for key in original.entity.attributesByName.keys { imported.setValue(original.value(forKey: key), forKey: key) }
            for key in original.entity.relationshipsByName.keys { imported.setValue(original.value(forKey: key), forKey: key) }
            context.transactionAuthor = "NSCloudKitMirroringDelegate.import"
            try context.save()
            let zone = CKRecordZone.ID(zoneName: "household-share", ownerName: "owner")
            return [original.objectID: CKRecord.ID(recordName: reverse ? "z" : "a", zoneID: zone),
                    imported.objectID: CKRecord.ID(recordName: reverse ? "a" : "z", zoneID: zone)]
        }
        return Fixture(persistence: persistence, service: service, householdID: scope.householdID,
                       needID: needID, listID: scope.listID, cart: cart, cartEntry: cartEntry, records: records, url: url)
    }
}
