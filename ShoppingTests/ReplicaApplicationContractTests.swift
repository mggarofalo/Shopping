import CoreData
import XCTest
@testable import Shopping

final class ReplicaApplicationContractTests: XCTestCase {
    private let lifetime = SQLiteTestFixtureLifetime()

    override func setUp() {
        super.setUp()
        let lifetime = lifetime
        addTeardownBlock { try lifetime.cleanup() }
    }

    func testDeliveryDistinguishesPhysicalDuplicatesFromReplayAndPreservesConflicts() throws {
        let f = try ReplicaContractFixture(lifetime: lifetime)
        let target = try f.copy()
        let original = try f.add()
        try f.deliver(f.cart, to: target, includeShared: false)
        let once = try f.recordCounts(target)
        try f.deliver(f.cart, to: target, includeShared: false)
        XCTAssertEqual(try f.recordCounts(target), once)
        try f.cart.transact { repository in
            let source = try XCTUnwrap(repository.privateRecords(kind: "cart").first)
            let duplicate = PersonalCartRecord(context: repository.context)
            repository.context.assign(duplicate, to: try XCTUnwrap(repository.persistence.primaryStore))
            duplicate.id = source.id
            duplicate.kind = source.kind
            duplicate.accountBinding = source.accountBinding
            duplicate.command = source.command
            duplicate.payload = source.payload
        }
        try f.deliver(f.cart, to: target, includeShared: false)
        let twice = try f.recordCounts(target)
        XCTAssertEqual(twice["private"], try XCTUnwrap(once["private"]) + 1)
        XCTAssertEqual(try f.entry(target).token, original.token)
        try f.deliver(f.cart, to: target, includeShared: false)
        XCTAssertEqual(try f.recordCounts(target), twice)
        try f.cart.transact { repository in
            let source = try XCTUnwrap(repository.privateRecords(kind: "cart").first)
            let conflict = PersonalCartRecord(context: repository.context)
            repository.context.assign(conflict, to: try XCTUnwrap(repository.persistence.primaryStore))
            conflict.id = source.id
            conflict.kind = source.kind
            conflict.accountBinding = source.accountBinding
            conflict.command = source.command
            conflict.payload = try PersonalCartCoding.encode(PersonalCartCommandResult(edit: nil, skipped: true))
        }
        try f.deliver(f.cart, to: target, includeShared: false)
        XCTAssertEqual(try f.recordCounts(target)["private"], try XCTUnwrap(twice["private"]) + 1)
        XCTAssertThrowsError(try target.entries(householdID: f.householdID, listID: f.listID)) {
            XCTAssertEqual($0 as? PersonalCartError, .corruptRecord)
        }
    }

    func testConcurrentQuantityTipsConvergeWithCompleteEvidenceAfterReplayAndReopen() throws {
        let f = try ReplicaContractFixture(lifetime: lifetime)
        let original = try f.add()
        let offline = try f.copy()
        let left = try f.copy()
        let right = try f.copy()
        let low = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        try f.cart.setQuantity(4, token: original.token, operationID: low)
        try offline.setQuantity(nil, token: original.token, operationID: high)
        try f.deliver(f.cart, to: left)
        try f.deliver(offline, to: left)
        try f.deliver(offline, to: right)
        try f.deliver(f.cart, to: right)
        for target in [left, right] {
            let entry = try f.entry(target)
            XCTAssertEqual(entry.id, original.id)
            XCTAssertNil(entry.quantity)
            XCTAssertEqual(entry.token.evidence, original.token.evidence.union([low, high]))
            XCTAssertEqual(try target.outstandingNeedIDs(householdID: f.householdID, listID: f.listID), [f.needID])
            let counts = try f.recordCounts(target)
            try f.deliver(f.cart, to: target)
            try f.deliver(offline, to: target)
            XCTAssertEqual(try f.recordCounts(target), counts)
            XCTAssertEqual(try f.entry(f.reopen(target)), entry)
        }
    }

    func testConcurrentRemovalWinsQuantityAndExplicitRecartCapturesBothBranches() throws {
        let f = try ReplicaContractFixture(lifetime: lifetime)
        let original = try f.add()
        let offline = try f.copy()
        let left = try f.copy()
        let right = try f.copy()
        let removeID = UUID()
        let quantityID = UUID()
        try f.cart.uncart(original.token, operationID: removeID)
        try offline.setQuantity(9, token: original.token, operationID: quantityID)
        try f.deliver(f.cart, to: left)
        try f.deliver(offline, to: left)
        try f.deliver(offline, to: right)
        try f.deliver(f.cart, to: right)
        for target in [left, right] {
            XCTAssertTrue(try target.entries(householdID: f.householdID, listID: f.listID).isEmpty)
            XCTAssertEqual(try target.outstandingNeedIDs(householdID: f.householdID, listID: f.listID), [f.needID])
            let recart = try f.add(target)
            XCTAssertNotEqual(recart.id, original.id)
            XCTAssertNil(recart.quantity)
            XCTAssertTrue(recart.token.evidence.isSuperset(of: original.token.evidence.union([removeID, quantityID])))
            XCTAssertEqual(try f.entry(f.reopen(target)), recart)
        }
    }

    func testChildBeforeParentImportFailsClosedThenRecoversWithoutLosingSavedPayload() throws {
        let f = try ReplicaContractFixture(lifetime: lifetime)
        let target = try f.copy()
        let original = try f.add()
        let childID = UUID()
        try f.cart.setQuantity(7, token: original.token, operationID: childID)
        try f.deliver(f.cart, to: target, privateIDs: [childID], includeShared: false)
        let importedCount = try f.recordCounts(target)
        XCTAssertThrowsError(try target.entries(householdID: f.householdID, listID: f.listID)) {
            XCTAssertEqual($0 as? PersonalCartError, .incompleteImport)
        }
        XCTAssertEqual(try f.recordCounts(target), importedCount)
        let reopened = try f.reopen(target)
        XCTAssertThrowsError(try reopened.entries(householdID: f.householdID, listID: f.listID)) {
            XCTAssertEqual($0 as? PersonalCartError, .incompleteImport)
        }
        try f.deliver(f.cart, to: reopened)
        let recovered = try f.entry(reopened)
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.quantity, 7)
        XCTAssertEqual(recovered.token.evidence, original.token.evidence.union([childID]))
        let results = try reopened.transact(save: false) { repository in
            try repository.values(PersonalCartCommandResult.self, kind: "cart")
        }
        XCTAssertEqual(Set(results.keys), original.token.evidence.union([childID]))
    }

    func testRestoreArrivingBeforeCheckoutConvergesAndDoesNotDuplicateRecovery() throws {
        let f = try ReplicaContractFixture(lifetime: lifetime)
        let original = try f.add()
        let target = try f.copy()
        let purchase = try f.cart.checkout(f.cart.prepareCheckout(tokens: [original.token]))
        _ = try f.cart.restore(checkoutID: purchase.operationID)
        let restoreIDs = try f.cart.transact(save: false) { repository in
            Set(try repository.privateRecords(kind: "restore").map(\.id))
        }
        XCTAssertEqual(restoreIDs.count, 1)
        try f.deliver(f.cart, to: target, privateIDs: restoreIDs, includeShared: false)
        XCTAssertEqual(try f.entry(target).token, original.token)
        XCTAssertTrue(try target.history(householdID: f.householdID, listID: f.listID).isEmpty)
        try f.deliver(f.cart, to: target)
        try target.resumePending()
        XCTAssertEqual(try f.entry(target).token, original.token)
        XCTAssertEqual(try target.outstandingNeedIDs(householdID: f.householdID, listID: f.listID), [f.needID])
        let history = try target.history(householdID: f.householdID, listID: f.listID)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, purchase.operationID)
        XCTAssertEqual(history.first?.restoredNeedIDs, [f.needID])
        let counts = try f.recordCounts(target)
        try f.deliver(f.cart, to: target)
        XCTAssertEqual(try f.recordCounts(target), counts)
        XCTAssertEqual(try f.reopen(target).history(householdID: f.householdID, listID: f.listID), history)
    }

    func testHouseholdOnlyImportsPreserveOtherShopperCartAndUndoNotice() throws {
        let f = try ReplicaContractFixture(lifetime: lifetime)
        let bob = try f.copy(shopper: "bob")
        let bobsEntry = try f.add(bob)
        let bobsPrivateCount = try f.recordCounts(bob)["private"]
        let alice = try f.add()
        let beforeRejectedImport = try f.recordCounts(bob)
        XCTAssertThrowsError(try f.deliver(f.cart, to: bob)) {
            XCTAssertEqual($0 as? PersonalCartError, .accountChanged)
        }
        XCTAssertEqual(try f.recordCounts(bob), beforeRejectedImport)
        try f.deliver(f.cart, to: bob, includePrivate: false)
        let presence = try bob.presence(householdID: f.householdID, listID: f.listID)
        XCTAssertEqual(presence.count, 1)
        XCTAssertEqual(presence.first?.needID, f.needID)
        XCTAssertEqual(try f.entry(bob).token, bobsEntry.token)
        let purchase = try f.cart.checkout(f.cart.prepareCheckout(tokens: [alice.token]))
        try f.deliver(f.cart, to: bob, includePrivate: false)
        let afterPurchase = try f.entry(bob)
        XCTAssertEqual(afterPurchase.token, bobsEntry.token)
        XCTAssertNil(afterPurchase.quantity)
        XCTAssertEqual(afterPurchase.purchaseNotices.count, 1)
        XCTAssertTrue(try bob.outstandingNeedIDs(householdID: f.householdID, listID: f.listID).isEmpty)
        XCTAssertTrue(try bob.history(householdID: f.householdID, listID: f.listID).isEmpty)
        XCTAssertThrowsError(try bob.uncart(alice.token)) {
            XCTAssertEqual($0 as? PersonalCartError, .accountChanged)
        }
        _ = try f.cart.restore(checkoutID: purchase.operationID)
        try f.deliver(f.cart, to: bob, includePrivate: false)
        XCTAssertEqual(try f.recordCounts(bob)["private"], bobsPrivateCount)
        try bob.transact(save: false) { repository in
            let rows = try repository.context.fetch(NSFetchRequest<PersonalCartRecord>(entityName: "PersonalCartRecord"))
            XCTAssertTrue(rows.allSatisfy { $0.accountBinding == bobsEntry.token.accountBinding })
        }
        let afterUndo = try f.entry(bob)
        XCTAssertEqual(afterUndo.token, bobsEntry.token)
        XCTAssertTrue(afterUndo.purchaseNotices.isEmpty)
        XCTAssertEqual(try bob.outstandingNeedIDs(householdID: f.householdID, listID: f.listID), [f.needID])
        XCTAssertEqual(try f.entry(f.reopen(bob, shopper: "bob")), afterUndo)
    }

    func testChangedUrgencyRetiresCapturedCheckoutWithoutChangingPrivateQuantity() throws {
        let f = try ReplicaContractFixture(lifetime: lifetime)
        let entry = try f.add()
        try f.cart.setQuantity(5, token: entry.token)
        let current = try f.entry(f.cart)
        let capture = try f.cart.prepareCheckout(tokens: [current.token])
        try f.needs.setUrgency(.urgent, needID: f.needID)
        let outcome = try f.cart.checkout(capture)
        XCTAssertEqual(outcome.purchasedNeedIDs, [])
        XCTAssertEqual(outcome.skippedNeedIDs, [f.needID])
        let reopened = try f.reopen(f.cart)
        XCTAssertEqual(try f.entry(reopened).quantity, 5)
        XCTAssertEqual(try f.entry(reopened).urgency, NeedUrgency.urgent.rawValue)
        XCTAssertEqual(try reopened.outstandingNeedIDs(householdID: f.householdID, listID: f.listID), [f.needID])
    }

    func testArchivedRestrictionRemainsRestrictedAndUrgentAfterSQLiteCopyAndReopen() throws {
        let f = try ReplicaContractFixture(lifetime: lifetime)
        let restricted = try f.needs.createStore(name: "Only here", householdID: f.householdID)
        let unrelated = try f.needs.createStore(name: "Elsewhere", householdID: f.householdID)
        try f.needs.setPurchaseRules(itemID: f.itemID, anyStore: false, storeIDs: [restricted])
        try f.needs.setUrgency(.urgent, needID: f.needID)
        try f.needs.setStoreArchived(true, storeID: restricted, householdID: f.householdID)
        let target = try f.copy()
        XCTAssertEqual(try NeedService(persistence: target.persistence).storeEligibility(itemID: f.itemID), .needsStore)
        let entry = try f.add(target)
        XCTAssertFalse(entry.anyStore)
        XCTAssertEqual(entry.storeIDs, [restricted])
        XCTAssertEqual(entry.urgency, NeedUrgency.urgent.rawValue)
        XCTAssertNil(entry.quantity)
        XCTAssertThrowsError(try target.prepareCheckout(tokens: [entry.token], storeID: unrelated)) {
            XCTAssertEqual($0 as? PersonalCartError, .staleEntry)
        }
        let reopened = try f.reopen(target)
        XCTAssertEqual(try f.entry(reopened), entry)
        XCTAssertEqual(try NeedService(persistence: reopened.persistence).storeEligibility(itemID: f.itemID), .needsStore)
    }
}
