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

    func testSuspendedShareAssociationCannotAcknowledgeAfterAccountOrStoreDetaches() throws {
        let f = try makeFixture()
        let provider = MutableSession(try session().session)
        _ = PersonalCartService(persistence: f.persistence, sessionProvider: provider)
        let store = try XCTUnwrap(f.persistence.primaryStore)
        XCTAssertNoThrow(try ManagedShareAssociationWorker.validateAuthority(persistence: f.persistence, store: store))
        provider.value = try session("bob").session
        XCTAssertThrowsError(try ManagedShareAssociationWorker.validateAuthority(persistence: f.persistence, store: store))
        provider.value = try session().session
        try f.persistence.container.persistentStoreCoordinator.remove(store)
        XCTAssertThrowsError(try ManagedShareAssociationWorker.validateAuthority(persistence: f.persistence, store: store))
    }

    func testMalformedSharedPurchaseCannotBlockPrivateQuantityOrRemovalAfterRelaunch() throws {
        let f = try makeFixture()
        let entry = try add(f)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let record = HouseholdCartRecord(context: context)
            record.id = UUID()
            record.kind = "purchase"
            record.household = try context.fetch(Household.fetchRequest()).first
            record.payload = nil
            try context.save()
        }
        XCTAssertThrowsError(try f.cart.prepareCheckout(tokens: [entry.token]))
        try f.cart.setQuantity(9, token: entry.token)
        let reopened = try PersistenceController(storeURL: f.directory.appendingPathComponent("store.sqlite"))
        let cart = PersonalCartService(persistence: reopened, sessionProvider: try session())
        let retained = try XCTUnwrap(cart.entries(householdID: f.householdID, listID: f.listID).first)
        XCTAssertEqual(retained.quantity, 9)
        try cart.uncart(retained.token)
        XCTAssertTrue(try cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
    }

    func testRememberedReaddAfterPrivateIntentBeforePublicationUsesNewOccurrence() throws {
        enum Injected: Error { case stopped }
        let f = try makeFixture()
        let entry = try add(f)
        let capture = try f.cart.prepareCheckout(tokens: [entry.token])
        let operationID = UUID()
        f.cart.failurePoint = { if $0 == "afterIntent" { throw Injected.stopped } }
        XCTAssertThrowsError(try f.cart.checkout(capture, operationID: operationID))
        f.cart.failurePoint = nil
        let replacement = try f.service.addRememberedNeed(itemID: f.itemID, listID: f.listID,
            householdID: f.householdID, quantity: 3)
        XCTAssertNotEqual(replacement, f.needID)
        _ = try f.cart.restore(checkoutID: operationID)
        let outstanding = try f.cart.outstandingNeedIDs(householdID: f.householdID, listID: f.listID)
        XCTAssertTrue(outstanding.contains(replacement))
        XCTAssertFalse(outstanding.contains(f.needID))
    }

    final class PrivateWritePolicy: PersistencePermissionPolicy {
        var denied = false
        func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {
            if denied && context.insertedObjects.contains(where: { $0 is PersonalCartRecord }) {
                throw PersistencePermissionError.updateDenied
            }
        }
    }

    func testAtomicInitialQuantityRollsBackWholeAdditionAndSurvivesRelaunch() throws {
        let policy = PrivateWritePolicy()
        let f = try makeFixture(permissionPolicy: policy)
        policy.denied = true
        XCTAssertThrowsError(try f.cart.cart(needID: f.needID, householdID: f.householdID,
            listID: f.listID, initialQuantity: 8))
        XCTAssertTrue(try f.cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
        policy.denied = false
        try f.cart.cart(needID: f.needID, householdID: f.householdID, listID: f.listID, initialQuantity: 8)
        let reopened = try PersistenceController(storeURL: f.directory.appendingPathComponent("store.sqlite"))
        let cart = PersonalCartService(persistence: reopened, sessionProvider: try session())
        XCTAssertEqual(try cart.entries(householdID: f.householdID, listID: f.listID).first?.quantity, 8)
        let context = reopened.simulationContext()
        try context.performAndWait { XCTAssertNil(try context.fetch(Need.fetchRequest()).first?.quantity) }
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

    func testLegacyPendingReviewExcludesManyEarlierPurchasesAndRetainsTheirRecovery() throws {
        let f = try makeFixture()
        var current = f.needID
        var firstOperation: UUID?
        for _ in 0..<12 {
            try f.service.setNeedCarted(needID: current, householdID: f.householdID, listID: f.listID, carted: true)
            let preview = try f.service.prepareClearCarted(householdID: f.householdID, listID: f.listID, filter: GroceryNeedFilter(carted: true))
            _ = try f.service.clearCarted(using: preview.token)
            firstOperation = firstOperation ?? preview.token.id
            current = try f.service.addRememberedNeed(itemID: f.itemID, listID: f.listID,
                householdID: f.householdID, quantity: nil)
        }
        try f.service.setNeedCarted(needID: current, householdID: f.householdID, listID: f.listID, carted: true)
        let context = f.persistence.simulationContext()
        let originalPayloads = try context.performAndWait { () -> [UUID: Data] in
            let operations = try context.fetch(ClearOperation.fetchRequest())
            let payloads = Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0.snapshot!) })
            let older = LegacyCartReview(context: context)
            older.id = UUID(); older.decision = "keep"; older.claimedAccount = ""
            older.payload = try PersonalCartCoding.encode(LegacyCartReviewSnapshot(id: older.id,
                householdID: f.householdID, listID: f.listID, needID: f.needID, title: "Milk", quantity: nil,
                oneTime: false, archived: true, oldCartedAt: nil,
                oldRecoveryPayload: payloads[firstOperation!], decision: "keep"))
            try context.save()
            return payloads
        }
        try f.cart.captureLegacyReview()
        let pending = try f.cart.pendingLegacyReview(householdID: f.householdID, listID: f.listID)
        XCTAssertEqual(pending.map(\.needID), [current])
        XCTAssertEqual(try f.cart.legacyReview().count, 2) // Existing build-13 audit row remains retained.
        try context.performAndWait {
            context.reset()
            let saved = try context.fetch(ClearOperation.fetchRequest())
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.snapshot!) }), originalPayloads)
            XCTAssertEqual(try context.fetch(Need.fetchRequest()).filter(\.archived).count, 12)
        }
        XCTAssertTrue(try f.cart.history(householdID: f.householdID, listID: f.listID).isEmpty)
        XCTAssertTrue(try f.cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
    }

    func testLegacyDiscardStaysDismissedAcrossRelaunchAndDelayedDuplicateImport() throws {
        let f = try makeFixture()
        try f.service.setNeedCarted(needID: f.needID, householdID: f.householdID, listID: f.listID, carted: true)
        try f.cart.captureLegacyReview()
        let review = try XCTUnwrap(f.cart.legacyReview().first)
        try f.cart.decideLegacyReview(id: review.id, claim: false)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let request = NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")
            let original = try XCTUnwrap(context.fetch(request).first)
            original.decision = "keep" // A delayed mirrored scalar must not reverse the durable decision.
            let duplicate = LegacyCartReview(context: context)
            duplicate.id = original.id; duplicate.payload = original.payload
            duplicate.decision = "keep"; duplicate.claimedAccount = ""
            try context.save()
        }
        let reopened = try PersistenceController(storeURL: f.directory.appendingPathComponent("store.sqlite"))
        let cart = PersonalCartService(persistence: reopened, sessionProvider: try session())
        try cart.captureLegacyReview()
        XCTAssertTrue(try cart.pendingLegacyReview(householdID: f.householdID, listID: f.listID).isEmpty)
        XCTAssertEqual(try cart.legacyReview().map(\.decision), ["discarded"])
        XCTAssertNoThrow(try cart.decideLegacyReview(id: review.id, claim: false))
        try reopened.writer.performAndWait {
            let need = try XCTUnwrap(reopened.writer.fetch(Need.fetchRequest()).first)
            XCTAssertTrue(need.carted); XCTAssertFalse(need.archived)
            XCTAssertEqual(try reopened.writer.fetch(NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")).count, 2)
        }
    }

    func testExistingBuild13DiscardIsUpgradedWithoutReturningToPendingReview() throws {
        let f = try makeFixture()
        try f.service.setNeedCarted(needID: f.needID, householdID: f.householdID, listID: f.listID, carted: true)
        try f.cart.captureLegacyReview()
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let record = try XCTUnwrap(context.fetch(NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")).first)
            record.decision = "discarded" // Build 13 wrote only this scalar decision.
            try context.save()
        }
        try f.cart.captureLegacyReview()
        try context.performAndWait {
            context.reset()
            let record = try XCTUnwrap(context.fetch(NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")).first)
            record.decision = "keep"
            try context.save()
        }
        XCTAssertTrue(try f.cart.pendingLegacyReview(householdID: f.householdID, listID: f.listID).isEmpty)
        XCTAssertEqual(try f.cart.legacyReview().first?.decision, "discarded")
        XCTAssertTrue(try f.cart.retainedScopes().isEmpty)
    }

    func testEquivalentLegacyReviewCopiesClaimOnceWithoutDuplicateOwnership() throws {
        let f = try makeFixture()
        try f.service.setNeedCarted(needID: f.needID, householdID: f.householdID, listID: f.listID, carted: true)
        try f.cart.captureLegacyReview()
        let review = try XCTUnwrap(f.cart.legacyReview().first)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let duplicate = LegacyCartReview(context: context)
            duplicate.id = review.id; duplicate.payload = try PersonalCartCoding.encode(review)
            duplicate.decision = "keep"; duplicate.claimedAccount = ""
            try context.save()
        }
        XCTAssertEqual(try f.cart.pendingLegacyReview(householdID: f.householdID, listID: f.listID).count, 1)
        try f.cart.decideLegacyReview(id: review.id, claim: true)
        try f.cart.decideLegacyReview(id: review.id, claim: true)
        XCTAssertTrue(try f.cart.pendingLegacyReview(householdID: f.householdID, listID: f.listID).isEmpty)
        XCTAssertEqual(try f.cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
    }

    func testEarlierClearRecoveryRestoresDemandWithoutPersonalOwnershipAndPreservesReplacement() throws {
        for readded in [false, true] {
            let f = try makeFixture()
            try f.service.setNeedCarted(needID: f.needID, householdID: f.householdID, listID: f.listID, carted: true)
            let preview = try f.service.prepareClearCarted(householdID: f.householdID, listID: f.listID, filter: GroceryNeedFilter(carted: true))
            _ = try f.service.clearCarted(using: preview.token)
            let replacement = readded ? try f.service.addRememberedNeed(itemID: f.itemID, listID: f.listID,
                householdID: f.householdID, quantity: 5) : nil
            // Activation/import can remap local store identities; recovery is qualified by captured logical IDs.
            let copiedURL = f.directory.appendingPathComponent("copied.sqlite")
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            try coordinator.replacePersistentStore(at: copiedURL, destinationOptions: nil,
                withPersistentStoreFrom: f.directory.appendingPathComponent("store.sqlite"), sourceOptions: nil,
                ofType: NSSQLiteStoreType)
            var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
                at: copiedURL, options: nil)
            metadata[NSStoreUUIDKey] = UUID().uuidString
            try NSPersistentStoreCoordinator.setMetadata(metadata, forPersistentStoreOfType: NSSQLiteStoreType,
                at: copiedURL, options: nil)
            let copied = try PersistenceController(storeURL: copiedURL)
            let cart = PersonalCartService(persistence: copied, sessionProvider: try session())
            let service = NeedService(persistence: copied)
            let recovered = try service.undoClear(operationID: preview.token.id,
                expectedHouseholdID: f.householdID, expectedListID: f.listID)
            XCTAssertEqual(recovered, readded ? 0 : 1)
            let outstanding = try cart.outstandingNeedIDs(householdID: f.householdID, listID: f.listID)
            XCTAssertEqual(outstanding, [replacement ?? f.needID])
            XCTAssertTrue(try cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
            XCTAssertTrue(try cart.history(householdID: f.householdID, listID: f.listID).isEmpty)
        }
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

    func testBuild13ScalarClaimRetryCannotResurrectLaterRemovedMembership() throws {
        for upgradeBeforeRetry in [false, true] {
            let f = try makeFixture()
            try f.service.setNeedCarted(needID: f.needID, householdID: f.householdID, listID: f.listID, carted: true)
            try f.cart.captureLegacyReview()
            let review = try XCTUnwrap(f.cart.legacyReview().first)
            let entry = try add(f)
            try f.cart.transact { repository in
                let request = NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")
                let record = try XCTUnwrap(repository.context.fetch(request).first)
                record.decision = "claimed"
                record.claimedAccount = repository.session.accountBinding
            }
            try f.cart.uncart(entry.token)
            if upgradeBeforeRetry { try f.cart.captureLegacyReview() }
            try f.cart.decideLegacyReview(id: review.id, claim: true)
            XCTAssertTrue(try f.cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
            XCTAssertEqual(try f.cart.transact(save: false) {
                Set(try $0.values(UUID.self, kind: "legacyClaim").values)
            }, [review.id])
            let reopened = try replica(of: f)
            try reopened.decideLegacyReview(id: review.id, claim: true)
            XCTAssertTrue(try reopened.entries(householdID: f.householdID, listID: f.listID).isEmpty)
            XCTAssertEqual(try reopened.legacyReview().first?.decision, "claimed")
        }
    }

    func testOfflineLegacyClaimsWithDifferentPriorCartStatesMergeWithoutConflictingReceipts() throws {
        for manuallyCarted in [false, true] {
            let f = try makeFixture()
            try f.service.setNeedCarted(needID: f.needID, householdID: f.householdID, listID: f.listID, carted: true)
            try f.cart.captureLegacyReview()
            let review = try XCTUnwrap(f.cart.legacyReview().first)
            let offline = try replica(of: f)
            if manuallyCarted { _ = try add(f) }
            try f.cart.decideLegacyReview(id: review.id, claim: true)
            try offline.decideLegacyReview(id: review.id, claim: true)

            // Import physical duplicates too: CloudKit can deliver distinct records with the
            // same application ID. Deduplicating by ID here would conceal unequal receipts.
            func importPrivateRows(_ source: PersonalCartService, into target: PersonalCartService) throws {
                let rows = try source.transact(save: false) { repository in
                    try repository.privateRecords().map { ($0.id, $0.kind, $0.accountBinding, $0.command, $0.payload) }
                }
                try target.transact { repository in
                    for row in rows {
                        let record = PersonalCartRecord(context: repository.context)
                        repository.context.assign(record, to: try XCTUnwrap(repository.persistence.primaryStore))
                        record.id = row.0; record.kind = row.1; record.accountBinding = row.2
                        record.command = row.3; record.payload = row.4
                    }
                }
            }
            try importPrivateRows(f.cart, into: offline)
            try importPrivateRows(offline, into: f.cart)
            let first = try f.cart.entries(householdID: f.householdID, listID: f.listID)
            let second = try offline.entries(householdID: f.householdID, listID: f.listID)
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(first.map(\.id), second.map(\.id))
            for cart in [f.cart, offline] {
                XCTAssertEqual(try cart.legacyReview().first?.decision, "claimed")
                XCTAssertTrue(try cart.pendingLegacyReview(householdID: f.householdID, listID: f.listID).isEmpty)
                XCTAssertNoThrow(try cart.decideLegacyReview(id: review.id, claim: true))
                XCTAssertEqual(try cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
            }
            let reopened = try replica(of: f)
            XCTAssertEqual(try reopened.entries(householdID: f.householdID, listID: f.listID).map(\.id), first.map(\.id))
            XCTAssertEqual(try reopened.legacyReview().first?.decision, "claimed")
        }
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
