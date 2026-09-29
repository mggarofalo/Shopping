import CoreData
import XCTest
@testable import Shopping

final class HomeSharingWorkSnapshotTests: XCTestCase {
    private struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }
    private struct Fixture {
        let persistence: PersistenceController
        let service: NeedService
        let cart: PersonalCartService
        let session: ShopperSession
        let homeID: UUID
        let listID: UUID
    }
    private let share = HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let persistence = try PersistenceController(storeURL: directory.appendingPathComponent("Store.sqlite"))
        addTeardownBlock {
            persistence.writer.performAndWait { persistence.writer.reset() }
            persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        let service = NeedService(persistence: persistence)
        let home = try service.createHousehold(name: "Home")
        let need = try service.addOneTimeNeed(title: "Milk", quantity: 1, householdID: home.householdID, listID: home.listID)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.work-status",
            environment: "Development", accountRecordName: "account-A")
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session))
        try cart.cart(needID: need, householdID: home.householdID, listID: home.listID)
        return Fixture(persistence: persistence, service: service, cart: cart, session: session,
            homeID: home.householdID, listID: home.listID)
    }

    private func pendingPurchase(_ f: Fixture) throws -> UUID {
        try f.cart.recordReadOnlyHome(householdID: f.homeID, listID: f.listID, share: share, operationID: UUID())
        let token = try f.cart.prepareCheckout(tokens: f.cart.entries(householdID: f.homeID, listID: f.listID).map(\.token))
        return try f.cart.checkout(token).operationID
    }

    func testCountsKnownOperationsAndHeldSubsetWithoutPublishingOrCrossingHomes() throws {
        let f = try fixture()
        let purchase = try pendingPurchase(f)
        _ = try f.cart.restore(checkoutID: purchase)
        let before = try f.cart.transact(save: false) { try $0.privateRecords().count }
        let snapshot = try f.cart.sharingWorkSnapshot(householdID: f.homeID, listID: f.listID)
        XCTAssertEqual(snapshot.pendingCheckoutCount, 1)
        XCTAssertEqual(snapshot.pendingUndoCount, 1)
        XCTAssertEqual(snapshot.heldCount, 2, "Held operations are a subset, not extra pending work")
        XCTAssertFalse(snapshot.isIncomplete)
        XCTAssertEqual(try f.cart.transact(save: false) { try $0.privateRecords().count }, before)
        XCTAssertTrue(try XCTUnwrap(f.cart.history(householdID: f.homeID, listID: f.listID).first).pendingPublication)

        let other = try f.service.createHousehold(name: "Other")
        let otherSnapshot = try f.cart.sharingWorkSnapshot(householdID: other.householdID, listID: other.listID)
        XCTAssertEqual(otherSnapshot.pendingCheckoutCount + otherSnapshot.pendingUndoCount, 0)
        let boundary = try f.cart.homePermissionBoundary(householdID: f.homeID, listID: f.listID)
        try f.cart.recordWritableHome(householdID: f.homeID, listID: f.listID, share: share,
            observedRestrictionIDs: boundary, operationID: UUID())
        try f.cart.resumePending()
        let processed = try f.cart.sharingWorkSnapshot(householdID: f.homeID, listID: f.listID)
        XCTAssertEqual(processed.pendingCheckoutCount + processed.pendingUndoCount, 0)
        XCTAssertEqual(processed.heldCount, 0)
    }

    func testPublishedCheckpointValuesExcludeOperationsWithoutInferringRemoteDelivery() throws {
        let f = try fixture()
        let purchase = try pendingPurchase(f)
        try f.cart.transact { repository in
            // The marker's own record ID is distinct from its referenced operation.
            try repository.insert(id: UUID(), kind: "published", command: purchase, value: purchase)
        }
        let snapshot = try f.cart.sharingWorkSnapshot(householdID: f.homeID, listID: f.listID)
        XCTAssertEqual(snapshot.pendingCheckoutCount, 0)
        XCTAssertEqual(snapshot.heldCheckoutCount, 0)
        XCTAssertFalse(f.persistence.configuration.isManaged, "No network delivery exists in this local fixture")
    }

    func testPartialRestoreImportKeepsKnownAndUnassignedWorkDistinct() throws {
        let f = try fixture()
        let scope = HomeEffectScope(session: f.session, householdID: f.homeID, listID: f.listID)
        try f.cart.transact { repository in
            let scoped = PersonalRestoreIntent(checkoutID: UUID(), restoredNeedIDs: [], homeEffectScope: scope)
            try repository.insert(id: UUID(), kind: "restore", command: scoped, value: scoped)
            let legacy = PersonalRestoreIntent(checkoutID: UUID(), restoredNeedIDs: [])
            try repository.insert(id: UUID(), kind: "restore", command: legacy, value: legacy)
        }
        let snapshot = try f.cart.sharingWorkSnapshot(householdID: f.homeID, listID: f.listID)
        XCTAssertEqual(snapshot.pendingUndoCount, 1)
        XCTAssertEqual(snapshot.incompleteUndoCount, 1)
        XCTAssertEqual(snapshot.unassignedUndoCount, 1)
        XCTAssertEqual(snapshot.heldUndoCount, 0, "Missing causal imports do not establish revocation")
        XCTAssertTrue(snapshot.isIncomplete)
    }

    func testAccountSnapshotNeverIncludesAnotherAccountsOperations() throws {
        let f = try fixture()
        _ = try pendingPurchase(f)
        let other = try ShopperSession.authenticated(containerIdentifier: f.session.containerIdentifier,
            environment: f.session.environment, accountRecordName: "account-B")
        let cart = PersonalCartService(persistence: f.persistence, sessionProvider: Provider(session: other))
        let snapshot = try cart.sharingWorkSnapshot(householdID: f.homeID, listID: f.listID)
        XCTAssertEqual(snapshot.scope.accountBinding, other.accountBinding)
        XCTAssertEqual(snapshot.pendingCheckoutCount + snapshot.pendingUndoCount, 0)
    }
}
