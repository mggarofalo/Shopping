import CoreData
import XCTest
@testable import Shopping

final class HomeEffectQuarantineTests: XCTestCase {
    private struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }
    private struct Fixture {
        let persistence: PersistenceController
        let cart: PersonalCartService
        let session: ShopperSession
        let homeID: UUID
        let listID: UUID
        let needID: UUID
        let url: URL
    }
    private enum Interruption: Error { case afterIntent }
    private let share = HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")

    private func close(_ persistence: PersistenceController) throws {
        persistence.writer.performAndWait { persistence.writer.reset() }
        persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Private.sqlite")
        let persistence = try PersistenceController(storeURL: url)
        addTeardownBlock { try self.close(persistence) }
        let service = NeedService(persistence: persistence)
        let home = try service.createHousehold(name: "Shared home")
        let need = try service.addOneTimeNeed(title: "Milk", quantity: 2, householdID: home.householdID, listID: home.listID)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.quarantine",
            environment: "Development", accountRecordName: "contributor")
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session))
        try cart.cart(needID: need, householdID: home.householdID, listID: home.listID)
        return Fixture(persistence: persistence, cart: cart, session: session, homeID: home.householdID,
            listID: home.listID, needID: need, url: url)
    }

    private func entry(_ f: Fixture) throws -> PersonalCartEntrySnapshot {
        try XCTUnwrap(f.cart.entries(householdID: f.homeID, listID: f.listID).first)
    }
    private func block(_ f: Fixture) throws -> UUID {
        let id = UUID()
        try f.cart.blockHomeEffects(householdID: f.homeID, listID: f.listID, share: share, reason: .left, operationID: id)
        return id
    }
    private func rejoin(_ f: Fixture) throws {
        try f.cart.grantHomeEffects(householdID: f.homeID, listID: f.listID, share: share,
            observedBlockIDs: f.cart.homeEffectBoundary(householdID: f.homeID, listID: f.listID), operationID: UUID())
    }
    private func sharedCount(_ f: Fixture, kind: String) throws -> Int {
        try f.cart.transact(save: false) { repository in
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            request.predicate = NSPredicate(format: "kind == %@", kind)
            return try repository.context.fetch(request).count
        }
    }

    private func replica(_ f: Fixture) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Replica.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: f.persistence.container.managedObjectModel)
        try coordinator.replacePersistentStore(at: url, destinationOptions: nil,
            withPersistentStoreFrom: f.url, sourceOptions: nil, ofType: NSSQLiteStoreType)
        let persistence = try PersistenceController(storeURL: url)
        addTeardownBlock { try self.close(persistence) }
        return Fixture(persistence: persistence,
            cart: PersonalCartService(persistence: persistence, sessionProvider: Provider(session: f.session)),
            session: f.session, homeID: f.homeID, listID: f.listID, needID: f.needID, url: url)
    }

    private func deliverPrivate(_ source: Fixture, to target: Fixture, kinds: Set<String>) throws {
        let rows = try source.cart.transact(save: false) { repository in
            try repository.privateRecords().filter { kinds.contains($0.kind) }
                .map { ($0.id, $0.kind, $0.accountBinding, $0.command, $0.payload) }
        }
        try target.cart.transact { repository in
            let known = Set(try repository.privateRecords().map(\.id))
            for row in rows where !known.contains(row.0) {
                let record = PersonalCartRecord(context: repository.context)
                repository.context.assign(record, to: try XCTUnwrap(repository.persistence.primaryStore))
                record.id = row.0; record.kind = row.1; record.accountBinding = row.2
                record.command = row.3; record.payload = row.4
            }
        }
    }

    func testPrivateCheckoutImportBeforeLifecycleCannotPublishOrFulfillDemand() throws {
        let source = try fixture()
        let target = try replica(source)
        _ = try block(source)
        let token = try source.cart.prepareCheckout(tokens: [entry(source).token])
        let purchase = try source.cart.checkout(token)
        XCTAssertTrue(purchase.pendingPublication)
        try deliverPrivate(source, to: target, kinds: ["checkout"])
        try target.cart.resumePending()
        XCTAssertEqual(try sharedCount(target, kind: "purchase"), 0)
        XCTAssertTrue(try target.cart.outstandingNeedIDs(householdID: target.homeID, listID: target.listID).contains(target.needID))
        XCTAssertTrue(try XCTUnwrap(target.cart.history(householdID: target.homeID, listID: target.listID).first).pendingPublication)
        try rejoin(source)
        try deliverPrivate(source, to: target, kinds: ["homeAccess"])
        try target.cart.resumePending()
        XCTAssertEqual(try sharedCount(target, kind: "purchase"), 0)
    }

    func testPrivateQuantityAndRemovalImportBeforeLifecycleCannotPublishPresence() throws {
        let source = try fixture()
        let target = try replica(source)
        let before = try sharedCount(target, kind: "presence")
        _ = try block(source)
        try source.cart.setQuantity(7, token: entry(source).token)
        try deliverPrivate(source, to: target, kinds: ["cart"])
        try target.cart.resumePending()
        XCTAssertEqual(try entry(target).quantity, 7)
        XCTAssertEqual(try sharedCount(target, kind: "presence"), before)
        try source.cart.uncart(entry(source).token)
        try deliverPrivate(source, to: target, kinds: ["cart"])
        try target.cart.resumePending()
        XCTAssertTrue(try target.cart.entries(householdID: target.homeID, listID: target.listID).isEmpty)
        XCTAssertEqual(try sharedCount(target, kind: "presence"), before)
    }

    func testPrivateRestoreImportBeforeLifecycleCannotPublishRetraction() throws {
        let source = try fixture()
        let purchase = try source.cart.checkout(source.cart.prepareCheckout(tokens: [entry(source).token]))
        let target = try replica(source)
        _ = try block(source)
        let restore = try source.cart.restore(checkoutID: purchase.operationID)
        XCTAssertTrue(restore.pendingPublication)
        try deliverPrivate(source, to: target, kinds: ["restore"])
        try target.cart.resumePending()
        XCTAssertEqual(try sharedCount(target, kind: "retraction"), 0)
        XCTAssertEqual(try target.cart.entries(householdID: target.homeID, listID: target.listID).count, 1)
    }

    func testRestoreArrivingBeforeItsCheckoutBlocksOtherOldPendingWorkInTheSameHome() throws {
        let source = try fixture()
        let target = try replica(source)
        let old = try target.cart.prepareCheckout(tokens: [entry(target).token])
        target.cart.failurePoint = { if $0 == "afterIntent" { throw Interruption.afterIntent } }
        XCTAssertThrowsError(try target.cart.checkout(old))
        target.cart.failurePoint = nil
        let purchase = try source.cart.checkout(source.cart.prepareCheckout(tokens: [entry(source).token]))
        let blockID = try block(source)
        _ = try source.cart.restore(checkoutID: purchase.operationID)
        try deliverPrivate(source, to: target, kinds: ["restore"])
        XCTAssertEqual(try target.cart.homeEffectBoundary(householdID: target.homeID, listID: target.listID), [blockID])
        try target.cart.resumePending()
        XCTAssertEqual(try sharedCount(target, kind: "purchase"), 0)
        XCTAssertEqual(try sharedCount(target, kind: "retraction"), 0)
        XCTAssertTrue(try target.cart.outstandingNeedIDs(householdID: target.homeID, listID: target.listID).contains(target.needID))
    }

    func testCheckoutCapturedBeforeLossCannotAcquireAuthorityAfterRejoin() throws {
        let f = try fixture()
        let token = try f.cart.prepareCheckout(tokens: [entry(f).token])
        _ = try block(f)
        try rejoin(f)
        XCTAssertThrowsError(try f.cart.checkout(token)) {
            XCTAssertEqual($0 as? PersonalCartError, .scopeChanged)
        }
        XCTAssertEqual(try entry(f).quantity, 2)
        XCTAssertTrue(try f.cart.history(householdID: f.homeID, listID: f.listID).isEmpty)
        XCTAssertEqual(try sharedCount(f, kind: "purchase"), 0)
    }

    func testInterruptedOldCheckoutStaysPrivateAcrossLeaveRejoinAndRestore() throws {
        let f = try fixture()
        let token = try f.cart.prepareCheckout(tokens: [entry(f).token])
        let id = UUID()
        f.cart.failurePoint = { if $0 == "afterIntent" { throw Interruption.afterIntent } }
        XCTAssertThrowsError(try f.cart.checkout(token, operationID: id))
        f.cart.failurePoint = nil
        XCTAssertFalse(try f.cart.outstandingNeedIDs(householdID: f.homeID, listID: f.listID).contains(f.needID))
        _ = try block(f)
        XCTAssertTrue(try f.cart.outstandingNeedIDs(householdID: f.homeID, listID: f.listID).contains(f.needID))
        try rejoin(f)
        try f.cart.resumePending()
        XCTAssertEqual(try sharedCount(f, kind: "purchase"), 0)
        XCTAssertTrue(try XCTUnwrap(f.cart.history(householdID: f.homeID, listID: f.listID).first).pendingPublication)
        let restore = try f.cart.restore(checkoutID: id)
        XCTAssertEqual(restore.purchasedNeedIDs, [f.needID])
        XCTAssertTrue(restore.pendingPublication)
        try f.cart.resumePending()
        XCTAssertEqual(try sharedCount(f, kind: "retraction"), 0)
        XCTAssertEqual(try entry(f).quantity, 2)
        let fresh = try f.cart.prepareCheckout(tokens: [entry(f).token])
        let purchase = try f.cart.checkout(fresh)
        XCTAssertFalse(purchase.pendingPublication)
        XCTAssertEqual(try sharedCount(f, kind: "purchase"), 1)
    }

    func testPrivateCleanupDoesNotRepublishOldGenerationAfterRejoin() throws {
        let f = try fixture()
        let original = try entry(f)
        let before = try sharedCount(f, kind: "presence")
        _ = try block(f)
        try f.cart.setQuantity(5, token: original.token)
        XCTAssertEqual(try entry(f).quantity, 5)
        XCTAssertEqual(try sharedCount(f, kind: "presence"), before)
        XCTAssertThrowsError(try f.cart.cart(needID: f.needID, householdID: f.homeID, listID: f.listID)) {
            XCTAssertEqual($0 as? PersonalCartError, .quarantined)
        }
        try rejoin(f)
        try f.cart.setQuantity(6, token: entry(f).token)
        XCTAssertEqual(try sharedCount(f, kind: "presence"), before)
        try f.cart.uncart(entry(f).token)
        XCTAssertTrue(try f.cart.entries(householdID: f.homeID, listID: f.listID).isEmpty)
        XCTAssertEqual(try sharedCount(f, kind: "presence"), before)
        try f.cart.cart(needID: f.needID, householdID: f.homeID, listID: f.listID)
        XCTAssertNotEqual(try entry(f).id, original.id)
        XCTAssertGreaterThan(try sharedCount(f, kind: "presence"), before)
        try f.cart.uncart(entry(f).token)
        XCTAssertEqual(try sharedCount(f, kind: "presence"), before + 2)
    }

    func testGrantImportedBeforeItsBlocksFailsClosedAndLaterBlockWins() throws {
        let f = try fixture()
        let scope = HomeEffectScope(session: f.session, householdID: f.homeID, listID: f.listID)
        let block = HomeAccessRecord(id: UUID(), scope: scope, share: share, action: .blocked(.revoked))
        let grant = HomeAccessRecord(id: UUID(), scope: scope, share: share, action: .joined(observedBlockIDs: [block.id]))
        let stamp = HomeEffectAuthority(observedBlockIDs: [block.id], grantID: grant.id)
        let incomplete = try HomeEffectAccess(records: [grant])
        XCTAssertFalse(incomplete.hasCompleteBoundary)
        XCTAssertFalse(incomplete.permitsPublication(.legacy))
        XCTAssertFalse(incomplete.permitsPublication(stamp))
        let complete = try HomeEffectAccess(records: [grant, block])
        XCTAssertTrue(complete.permitsPublication(stamp))
        XCTAssertFalse(complete.permitsPublication(.legacy))
        let later = HomeAccessRecord(id: UUID(), scope: scope, share: share, action: .blocked(.left))
        let revoked = try HomeEffectAccess(records: [grant, block, later])
        XCTAssertFalse(revoked.permitsPublication(stamp))
        XCTAssertThrowsError(try revoked.validateCapture(stamp))
    }

    func testBoundaryPersistsAfterReopenAndCannotGrantOverInterveningLoss() throws {
        let f = try fixture()
        let first = try block(f)
        let captured: Set<UUID> = [first]
        _ = try block(f)
        XCTAssertThrowsError(try f.cart.grantHomeEffects(householdID: f.homeID, listID: f.listID,
            share: share, observedBlockIDs: captured, operationID: UUID())) {
            XCTAssertEqual($0 as? PersonalCartError, .scopeChanged)
        }
        let boundary = try f.cart.homeEffectBoundary(householdID: f.homeID, listID: f.listID)
        XCTAssertEqual(boundary.count, 2)
        try close(f.persistence)
        let reopened = try PersistenceController(storeURL: f.url)
        addTeardownBlock { try self.close(reopened) }
        let cart = PersonalCartService(persistence: reopened, sessionProvider: Provider(session: f.session))
        XCTAssertEqual(try cart.homeEffectBoundary(householdID: f.homeID, listID: f.listID), boundary)
        let retained = try XCTUnwrap(cart.entries(householdID: f.homeID, listID: f.listID).first)
        try cart.uncart(retained.token)
        XCTAssertTrue(try cart.entries(householdID: f.homeID, listID: f.listID).isEmpty)
    }

    func testConcurrentSameShareGrantsCommuteButConflictingShareGrantsDoNotAuthorizeEffects() throws {
        let f = try fixture()
        let scope = HomeEffectScope(session: f.session, householdID: f.homeID, listID: f.listID)
        let block = HomeAccessRecord(id: UUID(), scope: scope, share: share, action: .blocked(.left))
        let first = HomeAccessRecord(id: UUID(), scope: scope, share: share, action: .joined(observedBlockIDs: [block.id]))
        let second = HomeAccessRecord(id: UUID(), scope: scope, share: share, action: first.action)
        let compatible = try HomeEffectAccess(records: [block, first, second])
        for id in [first.id, second.id] {
            XCTAssertTrue(compatible.permitsPublication(HomeEffectAuthority(observedBlockIDs: [block.id], grantID: id)))
        }
        let differentShare = HomeEffectShare(recordName: "other-share", zoneName: "other-zone", zoneOwnerName: "other-owner")
        let conflicting = HomeAccessRecord(id: UUID(), scope: scope, share: differentShare, action: first.action)
        let ambiguous = try HomeEffectAccess(records: [block, first, conflicting])
        XCTAssertFalse(ambiguous.permitsPublication(HomeEffectAuthority(observedBlockIDs: [block.id], grantID: first.id)))
        XCTAssertFalse(ambiguous.permitsPublication(ambiguous.capturedAuthority))
    }

    func testLossInOneHomeDoesNotBlockAnotherHomeInTheSamePrivateStore() throws {
        let f = try fixture()
        _ = try block(f)
        let service = NeedService(persistence: f.persistence)
        let home = try service.createHousehold(name: "Another home")
        let need = try service.addOneTimeNeed(title: "Beans", quantity: 1, householdID: home.householdID, listID: home.listID)
        try f.cart.cart(needID: need, householdID: home.householdID, listID: home.listID)
        let entry = try XCTUnwrap(f.cart.entries(householdID: home.householdID, listID: home.listID).first)
        let result = try f.cart.checkout(f.cart.prepareCheckout(tokens: [entry.token]))
        XCTAssertFalse(result.pendingPublication)
        XCTAssertEqual(result.purchasedNeedIDs, [need])
        XCTAssertEqual(try sharedCount(f, kind: "purchase"), 1)
    }

    func testLegacyCheckoutTokenWithoutAuthorityDecodesAndPublishesBeforeAnyLoss() throws {
        let f = try fixture()
        let captured = try f.cart.prepareCheckout(tokens: [entry(f).token])
        let encoded = try JSONEncoder().encode(captured)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "homeEffectAuthority")
        let legacy = try JSONDecoder().decode(PersonalCheckoutToken.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.homeEffectAuthority)
        let result = try f.cart.checkout(legacy)
        XCTAssertEqual(result.purchasedNeedIDs, [f.needID])
        XCTAssertFalse(result.pendingPublication)
    }
}
