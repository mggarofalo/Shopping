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

    func testImportedAccessFactsMergeWithoutTriggeringAnotherNativeObservation() async throws {
        let f = try fixture()
        let directory = try XCTUnwrap(f.persistence.primaryStore?.url?.deletingLastPathComponent())
        let consumer = PersistentHistoryConsumer(persistence: f.persistence,
            checkpoints: FileHistoryCheckpointStore(directory: directory.appendingPathComponent("History")))
        let initial = try await consumer.consumeSummary()
        XCTAssertEqual(initial.transactionCount, 0, "Local app commands do not trigger network verification")
        let imported = f.persistence.simulationContext()
        defer { imported.performAndWait { imported.reset() } }
        try imported.performAndWait {
            imported.transactionAuthor = "test.cloud.import"
            let value = HomeAccessRecord(id: UUID(),
                scope: HomeEffectScope(session: f.session, householdID: f.homeID, listID: f.listID),
                share: share, action: .blocked(.revoked))
            let record = PersonalCartRecord(context: imported)
            record.id = value.id
            record.accountBinding = f.session.accountBinding
            record.kind = "homeAccess"
            record.command = try PersonalCartCoding.encode(value)
            record.payload = try PersonalCartCoding.encode(value)
            try imported.save()
        }
        let observationImport = try await consumer.consumeSummary()
        XCTAssertEqual(observationImport.transactionCount, 1)
        XCTAssertFalse(observationImport.requiresAccessRefresh, "Observation records must not cause cross-device network/write loops")
        let snapshot = try HomeDiscoveryService(persistence: f.persistence).discover()
        XCTAssertEqual(snapshot.homes.first?.access, .unresolved, "The imported restriction must still affect local access")
        try imported.performAndWait {
            let need = try XCTUnwrap(imported.fetch(Need.fetchRequest()).first)
            need.title = "Imported grocery update"
            try imported.save()
        }
        let domainImport = try await consumer.consumeSummary()
        XCTAssertEqual(domainImport.transactionCount, 1)
        XCTAssertTrue(domainImport.requiresAccessRefresh, "Ordinary imports still revalidate access before replay")
        let repeated = try await consumer.consumeSummary()
        XCTAssertEqual(repeated.transactionCount, 0)
        XCTAssertFalse(repeated.requiresAccessRefresh)
    }

    @MainActor
    func testDiscoveryRetiresSelectedPermissionScopeAndDoesNotReplaceLostHome() throws {
        let f = try fixture()
        let suite = "HomePermissionSelection." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = ActiveHomeCoordinator(defaults: defaults)
        coordinator.bind(f.session)
        let discovery = HomeDiscoveryService(persistence: f.persistence)
        func reconcile() throws {
            let request = try XCTUnwrap(coordinator.beginDiscovery())
            XCTAssertTrue(coordinator.reconcile(try discovery.discover(), request: request))
        }
        try reconcile()
        let originalScope = try XCTUnwrap(coordinator.activeScope)
        let initialGeneration = coordinator.generation
        try restrict(f)
        try reconcile()
        XCTAssertEqual(coordinator.activeScope, originalScope)
        XCTAssertEqual(coordinator.homes.first?.access, .restricted)
        XCTAssertFalse(coordinator.isCurrent(scope: originalScope, generation: initialGeneration))
        let restrictedGeneration = coordinator.generation
        try reconcile()
        XCTAssertEqual(coordinator.generation, restrictedGeneration, "Unchanged observations must not recreate the screen repeatedly")
        try makeWritable(f)
        try reconcile()
        XCTAssertEqual(coordinator.homes.first?.access, .owner)
        XCTAssertGreaterThan(coordinator.generation, restrictedGeneration)
        _ = try f.service.createHousehold(name: "Other owned home")
        try f.cart.blockHomeEffects(householdID: f.homeID, listID: f.listID, share: share, reason: .revoked, operationID: UUID())
        try reconcile()
        XCTAssertEqual(coordinator.readiness, .selectedHomeUnavailable)
        XCTAssertNil(coordinator.activeScope)
        XCTAssertEqual(try entry(f).needID, f.needID)
        let reopened = ActiveHomeCoordinator(defaults: defaults)
        reopened.bind(f.session)
        XCTAssertTrue(reopened.reconcile(try discovery.discover(), request: try XCTUnwrap(reopened.beginDiscovery())))
        XCTAssertEqual(reopened.readiness, .selectedHomeUnavailable, "Do not automatically select the other home after relaunch")
    }
}
