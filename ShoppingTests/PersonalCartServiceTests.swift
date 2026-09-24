import CoreData
import XCTest
@testable import Shopping

final class PersonalCartServiceTests: XCTestCase {
    struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    struct Fixture {
        let persistence: PersistenceController
        let service: NeedService
        let cart: PersonalCartService
        let householdID: UUID
        let listID: UUID
        let needID: UUID
        let itemID: UUID
        let directory: URL
    }

    private func session(_ name: String = "alice") throws -> FixedSession {
        FixedSession(session: try ShopperSession.authenticated(containerIdentifier: "iCloud.shopping.tests",
            environment: "Development", accountRecordName: name))
    }

    private func makeFixture(permissionPolicy: PersistencePermissionPolicy? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let persistence = try PersistenceController(configuration: .local(storeURL: directory.appendingPathComponent("store.sqlite")), permissionPolicy: permissionPolicy)
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let itemID = try service.createItem(name: "Milk", householdID: selection.householdID)
        let needID = try service.addRememberedNeed(itemID: itemID, listID: selection.listID,
                                                  householdID: selection.householdID, quantity: nil)
        let cart = PersonalCartService(persistence: persistence, sessionProvider: try session())
        return Fixture(persistence: persistence, service: service, cart: cart, householdID: selection.householdID,
                       listID: selection.listID, needID: needID, itemID: itemID, directory: directory)
    }

    private func add(_ fixture: Fixture, cart: PersonalCartService? = nil) throws -> PersonalCartEntrySnapshot {
        let cart = cart ?? fixture.cart
        try cart.cart(needID: fixture.needID, householdID: fixture.householdID, listID: fixture.listID)
        return try XCTUnwrap(cart.entries(householdID: fixture.householdID, listID: fixture.listID).first)
    }

    func testOwnQuantityAndCleanupNeverMutateSharedDemandOrOtherOwner() throws {
        let f = try makeFixture()
        let alice = try add(f)
        let bob = PersonalCartService(persistence: f.persistence, sessionProvider: try session("bob"))
        let bobsEntry = try add(f, cart: bob)
        try f.cart.setQuantity(7, token: alice.token)
        XCTAssertEqual(try bob.entries(householdID: f.householdID, listID: f.listID), [bobsEntry])
        XCTAssertThrowsError(try bob.uncart(alice.token))
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", f.needID as CVarArg)
            let need = try XCTUnwrap(context.fetch(request).first)
            XCTAssertNil(need.quantity)
            XCTAssertFalse(need.carted)
        }
        let updated = try XCTUnwrap(f.cart.entries(householdID: f.householdID, listID: f.listID).first)
        try f.cart.uncart(updated.token)
        XCTAssertEqual(try bob.entries(householdID: f.householdID, listID: f.listID), [bobsEntry])
    }

    func testOtherShopperPurchaseNoticeBuyAnywayAndOneUndoPreservesOtherPurchase() throws {
        let f = try makeFixture()
        let alice = try add(f)
        let bob = PersonalCartService(persistence: f.persistence, sessionProvider: try session("bob"))
        let originalBob = try add(f, cart: bob)
        let token = try f.cart.prepareCheckout(tokens: [alice.token])
        let purchase = try f.cart.checkout(token)
        let bobAfter = try XCTUnwrap(bob.entries(householdID: f.householdID, listID: f.listID).first)
        XCTAssertEqual(bobAfter.token, originalBob.token)
        XCTAssertEqual(bobAfter.quantity, originalBob.quantity)
        XCTAssertEqual(bobAfter.purchaseNotices.count, 1)
        let bobToken = try bob.prepareCheckout(tokens: [bobAfter.token])
        let denied = try bob.checkout(bobToken)
        XCTAssertEqual(denied.skippedNeedIDs, [f.needID])
        let bobPurchase = try bob.checkout(bobToken, buyAnywayReceiptIDs: Set(bobAfter.purchaseNotices.map(\.receiptID)))
        XCTAssertEqual(bobPurchase.purchasedNeedIDs, [f.needID])
        _ = try f.cart.restore(checkoutID: purchase.operationID)
        XCTAssertFalse(try f.cart.outstandingNeedIDs(householdID: f.householdID, listID: f.listID).contains(f.needID))
        XCTAssertEqual(try f.cart.entries(householdID: f.householdID, listID: f.listID).first?.purchaseNotices.count, 1)
        XCTAssertThrowsError(try f.cart.restore(checkoutID: bobPurchase.operationID))
    }

    func testDurableIdempotencyAndChangedPayloadRejectionAcrossReopen() throws {
        let f = try makeFixture()
        let entry = try add(f)
        let token = try f.cart.prepareCheckout(tokens: [entry.token])
        let operationID = UUID()
        let first = try f.cart.checkout(token, operationID: operationID)
        let reopened = try PersistenceController(storeURL: f.directory.appendingPathComponent("store.sqlite"))
        let cart = PersonalCartService(persistence: reopened, sessionProvider: try session())
        XCTAssertEqual(try cart.checkout(token, operationID: operationID), first)
        XCTAssertThrowsError(try cart.checkout(token, buyAnywayReceiptIDs: [UUID()], operationID: operationID))
        let restoreID = UUID()
        let restored = try cart.restore(checkoutID: operationID, operationID: restoreID)
        XCTAssertEqual(try cart.restore(checkoutID: operationID, operationID: restoreID), restored)
        XCTAssertEqual(try cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
        XCTAssertEqual(try cart.history(householdID: f.householdID, listID: f.listID).count, 1)
    }

    func testEveryDurableCheckoutCrashBoundaryResumesWithoutDuplicateEffects() throws {
        enum Injected: Error { case crash }
        for point in ["beforeIntent", "afterIntent", "afterShared", "afterCompletion"] {
            let f = try makeFixture()
            let entry = try add(f)
            let token = try f.cart.prepareCheckout(tokens: [entry.token])
            let id = UUID()
            f.cart.failurePoint = { if $0 == point { throw Injected.crash } }
            XCTAssertThrowsError(try f.cart.checkout(token, operationID: id))
            let reopened = try PersistenceController(storeURL: f.directory.appendingPathComponent("store.sqlite"))
            let cart = PersonalCartService(persistence: reopened, sessionProvider: try session())
            try cart.resumePending()
            let history = try cart.history(householdID: f.householdID, listID: f.listID)
            if point == "beforeIntent" {
                XCTAssertTrue(history.isEmpty)
                XCTAssertEqual(try cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
            } else {
                XCTAssertEqual(history.count, 1)
                XCTAssertFalse(history[0].pendingPublication)
                XCTAssertTrue(try cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
                _ = try cart.restore(checkoutID: id)
                XCTAssertEqual(try cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
            }
        }
    }

    func testReplacementOccurrencePreventsOldRecoveryAndDoesNotInheritCart() throws {
        let f = try makeFixture()
        let entry = try add(f)
        let purchase = try f.cart.checkout(f.cart.prepareCheckout(tokens: [entry.token]))
        let replacement = try f.service.addRememberedNeed(itemID: f.itemID, listID: f.listID, householdID: f.householdID, quantity: 2)
        XCTAssertNotEqual(replacement, f.needID)
        let restore = try f.cart.restore(checkoutID: purchase.operationID)
        XCTAssertTrue(restore.purchasedNeedIDs.isEmpty)
        XCTAssertEqual(restore.skippedNeedIDs, [f.needID])
        XCTAssertEqual(try f.cart.outstandingNeedIDs(householdID: f.householdID, listID: f.listID), [replacement])
        XCTAssertTrue(try f.cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
    }

    func testChangedRequestedQuantityAndCatalogRuleSkipCapturedCheckout() throws {
        let f = try makeFixture()
        let entry = try add(f)
        let captured = try f.cart.prepareCheckout(tokens: [entry.token])
        try f.service.setNeedQuantity(needID: f.needID, householdID: f.householdID, listID: f.listID, quantity: 3)
        let changed = try f.cart.checkout(captured)
        XCTAssertEqual(changed.skippedNeedIDs, [f.needID])
        let second = try f.cart.prepareCheckout(tokens: [entry.token])
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let items = try context.fetch(Item.fetchRequest())
            let item = try XCTUnwrap(items.first { $0.id == f.itemID })
            item.revision += 1
            item.anyStore = false
            try context.save()
        }
        XCTAssertEqual(try f.cart.checkout(second).skippedNeedIDs, [f.needID])
    }

    func testUnknownLegacyOwnershipRequiresExplicitClaimAndIsRestartSafe() throws {
        let f = try makeFixture()
        try f.service.setNeedCarted(needID: f.needID, householdID: f.householdID, listID: f.listID, carted: true)
        try f.cart.captureLegacyReview()
        try f.cart.captureLegacyReview()
        let reviews = try f.cart.legacyReview()
        XCTAssertEqual(reviews.count, 1)
        XCTAssertTrue(try f.cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
        try f.cart.decideLegacyReview(id: reviews[0].id, claim: true)
        try f.cart.decideLegacyReview(id: reviews[0].id, claim: true)
        XCTAssertEqual(try f.cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
        XCTAssertNil(try f.cart.entries(householdID: f.householdID, listID: f.listID).first?.quantity)
        let bob = PersonalCartService(persistence: f.persistence, sessionProvider: try session("bob"))
        XCTAssertThrowsError(try bob.decideLegacyReview(id: reviews[0].id, claim: true))
    }

    func testPrivateRecordsNeverJoinHouseholdGraphAndUnauthorizedContextCannotWriteThem() throws {
        let f = try makeFixture()
        _ = try add(f)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let request = NSFetchRequest<PersonalCartRecord>(entityName: "PersonalCartRecord")
            let record = try XCTUnwrap(context.fetch(request).first)
            XCTAssertNil(ShareAssociationScope.household(for: record))
            XCTAssertTrue(record.entity.relationshipsByName.isEmpty)
            record.payload = Data()
            XCTAssertThrowsError(try f.persistence.prepareForSave(context))
            context.rollback()
        }
    }

    func testStaleOwnTokenOutcomeCannotLaterApplyAndGenerationChangesAfterRecart() throws {
        let f = try makeFixture()
        let first = try add(f)
        try f.cart.setQuantity(2, token: first.token)
        let id = UUID()
        XCTAssertThrowsError(try f.cart.uncart(first.token, operationID: id))
        let current = try XCTUnwrap(f.cart.entries(householdID: f.householdID, listID: f.listID).first)
        try f.cart.uncart(current.token)
        let recarted = try add(f)
        XCTAssertNotEqual(first.id, recarted.id)
        XCTAssertThrowsError(try f.cart.uncart(first.token, operationID: id))
        XCTAssertEqual(try f.cart.entries(householdID: f.householdID, listID: f.listID).first?.id, recarted.id)
    }
    private func replica(of f: Fixture) throws -> PersonalCartService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("replica.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: f.persistence.container.managedObjectModel)
        try coordinator.replacePersistentStore(at: target, destinationOptions: nil,
            withPersistentStoreFrom: f.directory.appendingPathComponent("store.sqlite"), sourceOptions: nil, ofType: NSSQLiteStoreType)
        return PersonalCartService(persistence: try PersistenceController(storeURL: target), sessionProvider: try session())
    }

    private func deliver(_ source: PersonalCartService, to target: PersonalCartService) throws {
        let values = try source.transact(save: false) { repository in
            let privateRows = try repository.privateRecords().map { ($0.id, $0.kind, $0.accountBinding, $0.command, $0.payload) }
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            let sharedRows = try repository.context.fetch(request).map { ($0.id, $0.kind, $0.payload, $0.household?.id) }
            return (privateRows, sharedRows)
        }
        try target.transact { repository in
            let known = Set(try repository.privateRecords().map(\.id))
            for row in values.0 where !known.contains(row.0) {
                let record = PersonalCartRecord(context: repository.context)
                repository.context.assign(record, to: try XCTUnwrap(repository.persistence.primaryStore))
                record.id = row.0; record.kind = row.1; record.accountBinding = row.2
                record.command = row.3; record.payload = row.4
            }
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            let knownShared = Set(try repository.context.fetch(request).map(\.id))
            for row in values.1 where !knownShared.contains(row.0) {
                let household = try repository.household(XCTUnwrap(row.3))
                let record = HouseholdCartRecord(context: repository.context)
                repository.context.assign(record, to: try XCTUnwrap(household.objectID.persistentStore))
                record.id = row.0; record.kind = row.1; record.payload = row.2; record.household = household
            }
        }
    }

    func testOfflineOwnQuantityVersusCheckoutConvergesInBothSQLiteDeliveryOrders() throws {
        let f = try makeFixture()
        let original = try add(f)
        let offline = try replica(of: f)
        let firstOrder = try replica(of: f)
        let secondOrder = try replica(of: f)
        let checkout = try f.cart.prepareCheckout(tokens: [original.token])
        try offline.setQuantity(6, token: original.token)
        _ = try f.cart.checkout(checkout)
        try deliver(f.cart, to: firstOrder)
        try deliver(offline, to: firstOrder)
        try deliver(offline, to: secondOrder)
        try deliver(f.cart, to: secondOrder)
        for target in [firstOrder, secondOrder] {
            let entry = try XCTUnwrap(target.entries(householdID: f.householdID, listID: f.listID).first)
            XCTAssertEqual(entry.quantity, 6)
            XCTAssertEqual(entry.id, original.id)
            XCTAssertEqual(entry.purchaseNotices.count, 1)
            try target.resumePending()
            XCTAssertEqual(try target.entries(householdID: f.householdID, listID: f.listID).first?.quantity, 6)
        }
    }

    func testOfflineRemoveReaddAndSharedDemandEditSurviveDelayedCheckout() throws {
        let f = try makeFixture()
        let original = try add(f)
        let offline = try replica(of: f)
        let firstOrder = try replica(of: f)
        let secondOrder = try replica(of: f)
        let checkout = try f.cart.prepareCheckout(tokens: [original.token])
        try offline.uncart(original.token)
        try offline.cart(needID: f.needID, householdID: f.householdID, listID: f.listID)
        try NeedService(persistence: offline.persistence).setNeedQuantity(needID: f.needID,
            householdID: f.householdID, listID: f.listID, quantity: 9)
        _ = try f.cart.checkout(checkout)
        try deliver(f.cart, to: firstOrder); try deliver(offline, to: firstOrder)
        try deliver(offline, to: secondOrder); try deliver(f.cart, to: secondOrder)
        for target in [firstOrder, secondOrder] {
            let entry = try XCTUnwrap(target.entries(householdID: f.householdID, listID: f.listID).first)
            XCTAssertNotEqual(entry.id, original.id)
            XCTAssertEqual(try target.outstandingNeedIDs(householdID: f.householdID, listID: f.listID), [f.needID])
        }
    }

    func testSharedRetractionCannotRestorePrivateCartAndMissingPresenceCannotUncartIt() throws {
        let f = try makeFixture()
        let entry = try add(f)
        let purchase = try f.cart.checkout(f.cart.prepareCheckout(tokens: [entry.token]))
        try f.cart.transact { repository in
            let receiptID = PersonalCartCoding.stableID("purchase", purchase.operationID.uuidString, f.needID.uuidString)
            let forged = HouseholdRetractionEvent(id: UUID(), receiptIDs: [receiptID])
            try repository.publish(forged, id: forged.id, kind: "retraction", householdID: f.householdID)
        }
        XCTAssertTrue(try f.cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
        _ = try f.cart.restore(checkoutID: purchase.operationID)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            request.predicate = NSPredicate(format: "kind == %@", "presence")
            try context.fetch(request).forEach(context.delete)
            try context.save()
        }
        XCTAssertEqual(try f.cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
        try f.cart.republishPresence()
        let before = try f.cart.transact(save: false) { repository in
            try repository.context.count(for: NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord"))
        }
        try f.cart.republishPresence()
        let after = try f.cart.transact(save: false) { repository in
            try repository.context.count(for: NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord"))
        }
        XCTAssertEqual(before, after)
    }

    func testPrivateCartRetainsSnapshotAfterHouseholdGraphDisappearsAndCanBeRemoved() throws {
        let f = try makeFixture()
        let entry = try add(f)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            for need in try context.fetch(Need.fetchRequest()) { context.delete(need) }
            for item in try context.fetch(Item.fetchRequest()) { context.delete(item) }
            for household in try context.fetch(Household.fetchRequest()) { context.delete(household) }
            try context.save()
        }
        let retained = try XCTUnwrap(f.cart.entries(householdID: f.householdID, listID: f.listID).first)
        XCTAssertEqual(retained.title, "Milk")
        XCTAssertFalse(retained.demandAvailable)
        XCTAssertEqual(retained.token, entry.token)
        try f.cart.uncart(retained.token)
        XCTAssertTrue(try f.cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
    }

    final class MutableSession: ShopperSessionProviding, @unchecked Sendable {
        var value: ShopperSession
        init(_ value: ShopperSession) { self.value = value }
        func currentSession() throws -> ShopperSession { value }
    }

    func testOldServiceAndSharedCommandsRefuseNewAccountBeforeBootstrapDetachesStore() throws {
        let f = try makeFixture()
        let provider = MutableSession(try session().session)
        let cart = PersonalCartService(persistence: f.persistence, sessionProvider: provider)
        provider.value = try session("bob").session
        XCTAssertThrowsError(try cart.cart(needID: f.needID, householdID: f.householdID, listID: f.listID))
        XCTAssertThrowsError(try cart.captureLegacyReview())
        XCTAssertThrowsError(try f.service.setQuantity(4, needID: f.needID))
        provider.value = try session().session
        XCTAssertTrue(try cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
    }

    func testUnavailableHouseholdQuarantinesOutboxButRetainsPrivateHistoryAndCleanup() throws {
        enum Injected: Error { case stop }
        let f = try makeFixture()
        let entry = try add(f)
        let token = try f.cart.prepareCheckout(tokens: [entry.token])
        f.cart.failurePoint = { if $0 == "afterIntent" { throw Injected.stop } }
        XCTAssertThrowsError(try f.cart.checkout(token))
        f.cart.failurePoint = nil
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            for household in try context.fetch(Household.fetchRequest()) { context.delete(household) }
            try context.save()
        }
        XCTAssertNoThrow(try f.cart.resumePending())
        let history = try f.cart.history(householdID: f.householdID, listID: f.listID)
        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(history[0].pendingPublication)
    }

    final class SharedWritePolicy: PersistencePermissionPolicy {
        var denied = false
        func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {
            if denied && context.insertedObjects.union(context.updatedObjects).contains(where: { $0 is HouseholdCartRecord }) {
                throw PersistencePermissionError.updateDenied
            }
        }
    }

    func testReadOnlyHouseholdLeavesCheckoutPendingAndDoesNotBlockPrivateRecoveryOrRemoval() throws {
        let policy = SharedWritePolicy()
        let f = try makeFixture(permissionPolicy: policy)
        let entry = try add(f)
        let token = try f.cart.prepareCheckout(tokens: [entry.token])
        policy.denied = true
        let purchase = try f.cart.checkout(token)
        XCTAssertTrue(purchase.pendingPublication)
        XCTAssertNoThrow(try f.cart.resumePending())
        XCTAssertEqual(try f.cart.history(householdID: f.householdID, listID: f.listID).count, 1)
        let restore = try f.cart.restore(checkoutID: purchase.operationID)
        XCTAssertTrue(restore.pendingPublication)
        let restored = try XCTUnwrap(f.cart.entries(householdID: f.householdID, listID: f.listID).first)
        try f.cart.uncart(restored.token)
        XCTAssertTrue(try f.cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
    }

    func testPartialAndZeroRecoveryNeverReportWholePurchaseUndone() throws {
        let f = try makeFixture()
        let milk = try add(f)
        let eggsID = try f.service.addOneTimeNeed(title: "Eggs", householdID: f.householdID, listID: f.listID)
        try f.cart.cart(needID: eggsID, householdID: f.householdID, listID: f.listID)
        let entries = try f.cart.entries(householdID: f.householdID, listID: f.listID)
        let purchase = try f.cart.checkout(f.cart.prepareCheckout(tokens: entries.map(\.token)))
        try f.service.setNeedQuantity(needID: milk.needID, householdID: f.householdID, listID: f.listID, quantity: 5)
        let partial = try f.cart.restore(checkoutID: purchase.operationID)
        XCTAssertEqual(partial.purchasedNeedIDs, [eggsID])
        XCTAssertEqual(partial.skippedNeedIDs, [milk.needID])
        let history = try XCTUnwrap(f.cart.history(householdID: f.householdID, listID: f.listID).first)
        XCTAssertFalse(history.restored)
        XCTAssertEqual(history.restoredNeedIDs, [eggsID])
        let zero = try f.cart.restore(checkoutID: purchase.operationID)
        XCTAssertTrue(zero.purchasedNeedIDs.isEmpty)
        XCTAssertFalse(try XCTUnwrap(f.cart.history(householdID: f.householdID, listID: f.listID).first).restored)
    }

    func testLatePurchaseRuleImportReexposesDemandInBothReceiptDeliveryOrders() throws {
        let f = try makeFixture()
        let storeID = try f.service.createStore(name: "Only here", householdID: f.householdID)
        let entry = try add(f)
        let beforeReceipt = try replica(of: f)
        let afterReceipt = try replica(of: f)
        let capture = try f.cart.prepareCheckout(tokens: [entry.token])
        _ = try f.cart.checkout(capture)
        func changeRules(_ target: PersonalCartService) throws {
            let context = target.persistence.simulationContext()
            try context.performAndWait {
                let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first { $0.id == f.itemID })
                let store = try XCTUnwrap(context.fetch(Store.fetchRequest()).first { $0.id == storeID })
                item.anyStore = false
                item.stores = [store]
                try context.save() // Deliberately no Need or Item revision bump: relationship evidence owns safety.
            }
        }
        try changeRules(beforeReceipt)
        try deliver(f.cart, to: beforeReceipt)
        try deliver(f.cart, to: afterReceipt)
        XCTAssertFalse(try afterReceipt.outstandingNeedIDs(householdID: f.householdID, listID: f.listID).contains(f.needID))
        try changeRules(afterReceipt)
        for target in [beforeReceipt, afterReceipt] {
            XCTAssertEqual(try target.outstandingNeedIDs(householdID: f.householdID, listID: f.listID), [f.needID])
            XCTAssertEqual(try target.history(householdID: f.householdID, listID: f.listID).count, 1)
        }
    }

    func testCyclicImportedCausalityIsPreservedAndRejectedInsteadOfEmptyCart() throws {
        let f = try makeFixture()
        let entry = try add(f)
        let first = UUID(), second = UUID()
        try f.cart.transact { repository in
            for (id, parent) in [(first, second), (second, first)] {
                let edit = PersonalCartEdit(id: id, action: .quantity, snapshot: entry,
                    ancestors: entry.token.evidence.union([parent]))
                try repository.insert(id: id, kind: "cart", command: PersonalCartCommand.quantity(entry.token, 2),
                    value: PersonalCartCommandResult(edit: edit, skipped: false))
            }
        }
        XCTAssertThrowsError(try f.cart.entries(householdID: f.householdID, listID: f.listID)) { error in
            XCTAssertEqual(error as? PersonalCartError, .corruptRecord)
        }
        let count = try f.cart.transact(save: false) { try $0.privateRecords(kind: "cart").count }
        XCTAssertEqual(count, 3, "Conflicting evidence is retained for diagnosis, not erased")
    }

    func testImportedLegacyDiscardCannotHideImmutableSuccessfulClaim() throws {
        let f = try makeFixture()
        try f.service.setNeedCarted(needID: f.needID, householdID: f.householdID, listID: f.listID, carted: true)
        try f.cart.captureLegacyReview()
        let review = try XCTUnwrap(f.cart.legacyReview().first)
        try f.cart.decideLegacyReview(id: review.id, claim: true)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let request = NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")
            let record = try XCTUnwrap(context.fetch(request).first)
            record.decision = "discarded" // Simulate a delayed same-account legacy decision merge.
            try context.save()
        }
        XCTAssertEqual(try f.cart.legacyReview().first?.decision, "claimed")
        XCTAssertEqual(try f.cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
        XCTAssertNoThrow(try f.cart.decideLegacyReview(id: review.id, claim: true))
        XCTAssertThrowsError(try f.cart.decideLegacyReview(id: review.id, claim: false))
    }

}
