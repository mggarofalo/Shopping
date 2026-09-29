import CoreData
import XCTest
@testable import Shopping

final class HomePermissionTests: XCTestCase {
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
        let needID: UUID
    }
    private let share = HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
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
        let needID = try service.addOneTimeNeed(title: "Milk", quantity: 2, householdID: home.householdID, listID: home.listID)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.permissions",
            environment: "Development", accountRecordName: "contributor")
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session))
        try cart.cart(needID: needID, householdID: home.householdID, listID: home.listID)
        return Fixture(persistence: persistence, service: service, cart: cart, session: session,
            homeID: home.householdID, listID: home.listID, needID: needID)
    }
    private func entry(_ f: Fixture) throws -> PersonalCartEntrySnapshot {
        try XCTUnwrap(f.cart.entries(householdID: f.homeID, listID: f.listID).first)
    }
    private func restrict(_ f: Fixture) throws {
        try f.cart.recordReadOnlyHome(householdID: f.homeID, listID: f.listID, share: share, operationID: UUID())
    }
    private func makeWritable(_ f: Fixture, boundary: Set<UUID>? = nil) throws {
        let captured = try boundary ?? f.cart.homePermissionBoundary(householdID: f.homeID, listID: f.listID)
        try f.cart.recordWritableHome(householdID: f.homeID, listID: f.listID, share: share,
            observedRestrictionIDs: captured, operationID: UUID())
    }

    func testObservedReadOnlyBlocksSharedWritesAndStaleCheckoutButRetainsPrivateRecovery() throws {
        let f = try fixture()
        let stale = try f.cart.prepareCheckout(tokens: [entry(f).token])
        try restrict(f)
        XCTAssertThrowsError(try f.cart.checkout(stale)) { XCTAssertEqual($0 as? PersonalCartError, .scopeChanged) }
        XCTAssertThrowsError(try f.service.setNeedQuantity(needID: f.needID, householdID: f.homeID, listID: f.listID, quantity: 9)) {
            XCTAssertEqual($0 as? PersistencePermissionError, .updateDenied)
        }
        XCTAssertThrowsError(try f.service.createPerson(name: "Must not insert", householdID: f.homeID)) {
            XCTAssertEqual($0 as? PersistencePermissionError, .updateDenied)
        }
        try f.cart.setQuantity(3, token: entry(f).token)
        XCTAssertEqual(try entry(f).quantity, 3)
        let privatePurchase = try f.cart.checkout(f.cart.prepareCheckout(tokens: [entry(f).token]))
        XCTAssertTrue(privatePurchase.pendingPublication)
        XCTAssertTrue(try f.cart.outstandingNeedIDs(householdID: f.homeID, listID: f.listID).contains(f.needID))
        let restored = try f.cart.restore(checkoutID: privatePurchase.operationID)
        XCTAssertTrue(restored.pendingPublication)
        XCTAssertEqual(restored.purchasedNeedIDs, [f.needID])
        try f.cart.uncart(entry(f).token)
        XCTAssertTrue(try f.cart.entries(householdID: f.homeID, listID: f.listID).isEmpty)
        try makeWritable(f)
        try f.service.setNeedQuantity(needID: f.needID, householdID: f.homeID, listID: f.listID, quantity: 4)
        try f.cart.resumePending()
        let history = try XCTUnwrap(f.cart.history(householdID: f.homeID, listID: f.listID).first)
        XCTAssertTrue(history.restored)
        XCTAssertFalse(history.pendingPublication, "A temporary permission restriction can resume after verified writable access")
        XCTAssertThrowsError(try f.cart.checkout(stale)) { XCTAssertEqual($0 as? PersonalCartError, .scopeChanged) }
    }

    func testRestrictionRetryIsIdempotentAndNewerReadOnlyObservationFencesOldWritableResponse() throws {
        let f = try fixture()
        let observationID = UUID()
        try f.cart.recordReadOnlyHome(householdID: f.homeID, listID: f.listID, share: share, operationID: observationID)
        let boundary = try f.cart.homePermissionBoundary(householdID: f.homeID, listID: f.listID)
        try f.cart.recordReadOnlyHome(householdID: f.homeID, listID: f.listID, share: share, operationID: observationID)
        XCTAssertEqual(try f.cart.homePermissionBoundary(householdID: f.homeID, listID: f.listID), boundary)
        XCTAssertThrowsError(try makeWritable(f, boundary: [])) { XCTAssertEqual($0 as? PersonalCartError, .scopeChanged) }
        // A second observation arrives while the earlier writable request is held.
        try restrict(f)
        XCTAssertEqual(try f.cart.homePermissionBoundary(householdID: f.homeID, listID: f.listID).count, 2)
        XCTAssertThrowsError(try makeWritable(f, boundary: boundary)) { XCTAssertEqual($0 as? PersonalCartError, .scopeChanged) }
        XCTAssertThrowsError(try f.service.createPerson(name: "Still restricted", householdID: f.homeID)) {
            XCTAssertEqual($0 as? PersistencePermissionError, .updateDenied)
        }
        try makeWritable(f)
        XCTAssertNoThrow(try f.service.createPerson(name: "Freshly verified", householdID: f.homeID))
    }

    func testPermanentLossCannotBeClearedByWritablePermissionObservation() throws {
        let f = try fixture()
        try f.cart.blockHomeEffects(householdID: f.homeID, listID: f.listID, share: share, reason: .revoked, operationID: UUID())
        try restrict(f)
        try makeWritable(f)
        XCTAssertThrowsError(try f.service.setNeedQuantity(needID: f.needID, householdID: f.homeID, listID: f.listID, quantity: 9)) {
            XCTAssertEqual($0 as? PersistencePermissionError, .updateDenied)
        }
        try f.cart.setQuantity(4, token: entry(f).token)
        XCTAssertEqual(try entry(f).quantity, 4)
        let other = try f.service.createHousehold(name: "My own home")
        XCTAssertNoThrow(try f.service.createPerson(name: "Still writable", householdID: other.householdID))
    }

    func testWritableRecordBeforeRestrictionCannotAuthorizeEarlyPublication() throws {
        let f = try fixture()
        let scope = HomeEffectScope(session: f.session, householdID: f.homeID, listID: f.listID)
        let restricted = HomeAccessRecord(id: UUID(), scope: scope, share: share, action: .readOnly)
        let restored = HomeAccessRecord(id: UUID(), scope: scope, share: share,
            action: .writable(observedRestrictionIDs: [restricted.id]))
        let incomplete = try HomeEffectAccess(records: [restored])
        XCTAssertFalse(incomplete.permitsPublication(.legacy))
        let complete = try HomeEffectAccess(records: [restricted, restored])
        XCTAssertTrue(complete.permitsPublication(.legacy), "Pending pre-restriction work may resume after the temporary restriction resolves")
        XCTAssertThrowsError(try complete.validateCapture(.legacy), "An uncommitted pre-restriction capture still needs fresh review")
        let effectBeforeRestriction = try HomeEffectAccess(records: [], requiredRestrictionIDs: [restricted.id])
        XCTAssertFalse(effectBeforeRestriction.permitsPublication(.legacy))
    }

    func testMovingNeedOutOfRestrictedHomeCannotBypassOriginalHomeGate() throws {
        let f = try fixture()
        let other = try f.service.createHousehold(name: "Writable home")
        try restrict(f)
        XCTAssertThrowsError(try f.cart.transact { repository in
            let need = try XCTUnwrap(repository.need(f.needID, householdID: f.homeID, listID: f.listID))
            let home = try repository.household(other.householdID)
            need.list = home.groceryList
        }) { XCTAssertEqual($0 as? PersistencePermissionError, .updateDenied) }
        XCTAssertEqual(try entry(f).needID, f.needID)
    }
}
