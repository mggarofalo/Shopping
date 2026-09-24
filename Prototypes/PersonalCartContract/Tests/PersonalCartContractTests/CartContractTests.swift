import Foundation
import XCTest
@testable import PersonalCartContract

final class CartContractTests: XCTestCase {
    private func seeded(_ owner: String = "alice") throws -> CartContract {
        var state = CartContract(authenticatedOwner: owner)
        try state.demand(DemandEdit(id: "d1", occurrence: "milk"))
        try state.edit(CartEdit(id: "a1", owner: owner, occurrence: "milk", generation: "g1",
                               ancestors: [], kind: .add, quantity: nil))
        return state
    }

    private func roundTrip(_ value: CartContract) throws -> CartContract {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        try value.save(to: url)
        return try CartContract.reopen(url)
    }

    func testUnseenOfflineQuantitySurvivesCheckoutInBothDeliveryOrders() throws {
        let base = try seeded()
        var buyer = base
        let token = try buyer.capture(id: "purchase", occurrence: "milk")
        try buyer.confirm(token)
        try buyer.resume()
        XCTAssertNil(buyer.snapshot("milk"))
        var offline = base
        try offline.edit(CartEdit(id: "q2", owner: "alice", occurrence: "milk", generation: "g1",
                                 ancestors: ["a1"], kind: .quantity, quantity: 3))
        for reverse in [false, true] {
            var joined = reverse ? offline : buyer
            try joined.merge(reverse ? buyer : offline)
            joined = try roundTrip(joined)
            XCTAssertEqual(joined.snapshot("milk")?.quantity, 3)
            XCTAssertEqual(joined.snapshot("milk")?.alreadyPurchased, true)
        }
    }

    func testRemoveReaddAndDemandEditSurviveDelayedCheckout() throws {
        let base = try seeded()
        var buyer = base
        try buyer.confirm(buyer.capture(id: "purchase", occurrence: "milk"))
        try buyer.resume()
        var offline = base
        try offline.edit(CartEdit(id: "r2", owner: "alice", occurrence: "milk", generation: "g1",
                                 ancestors: ["a1"], kind: .remove, quantity: nil))
        try offline.edit(CartEdit(id: "a3", owner: "alice", occurrence: "milk", generation: "g2",
                                 ancestors: ["a1", "r2"], kind: .add, quantity: 4))
        try offline.demand(DemandEdit(id: "d2", occurrence: "milk"))
        try offline.demand(DemandEdit(id: "new-occurrence", occurrence: "milk-again"))
        for reverse in [false, true] {
            var joined = reverse ? offline : buyer
            try joined.merge(reverse ? buyer : offline)
            XCTAssertEqual(joined.snapshot("milk")?.generation, "g2")
            XCTAssertTrue(joined.isOutstanding("milk"))
            XCTAssertTrue(joined.isOutstanding("milk-again"))
        }
    }

    func testConcurrentRemoveWinsButCausallyLaterAddWins() throws {
        let base = try seeded()
        var removed = base
        try removed.edit(CartEdit(id: "r2", owner: "alice", occurrence: "milk", generation: "g1",
                                 ancestors: ["a1"], kind: .remove, quantity: nil))
        var edited = base
        try edited.edit(CartEdit(id: "z2", owner: "alice", occurrence: "milk", generation: "g1",
                                ancestors: ["a1"], kind: .quantity, quantity: 7))
        try edited.merge(removed)
        XCTAssertNil(edited.snapshot("milk"))
        try edited.edit(CartEdit(id: "a3", owner: "alice", occurrence: "milk", generation: "g2",
                                ancestors: ["a1", "r2", "z2"], kind: .add, quantity: 2))
        XCTAssertEqual(edited.snapshot("milk")?.quantity, 2)
        XCTAssertEqual(edited.cartEdits.count, 4, "Losing quantity remains recoverable")
    }

    func testConcurrentScalarDeterminismAndCausalSuccessor() throws {
        let base = try seeded()
        var phone = base
        var watch = base
        try phone.edit(CartEdit(id: "q2", owner: "alice", occurrence: "milk", generation: "g1",
                               ancestors: ["a1"], kind: .quantity, quantity: 2))
        try watch.edit(CartEdit(id: "q3", owner: "alice", occurrence: "milk", generation: "g1",
                               ancestors: ["a1"], kind: .quantity, quantity: 3))
        var left = phone
        try left.merge(watch)
        try watch.merge(phone)
        XCTAssertEqual(left.snapshot("milk"), watch.snapshot("milk"))
        XCTAssertEqual(left.snapshot("milk")?.quantity, 3)
        try left.edit(CartEdit(id: "q0", owner: "alice", occurrence: "milk", generation: "g1",
                              ancestors: ["a1", "q2", "q3"], kind: .quantity, quantity: 9))
        XCTAssertEqual(left.snapshot("milk")?.quantity, 9, "Causality beats lexical order")
        try left.edit(CartEdit(id: "eggs", owner: "alice", occurrence: "eggs", generation: "e1",
                              ancestors: [], kind: .add, quantity: 1))
        XCTAssertEqual(left.snapshot("eggs")?.quantity, 1)
        XCTAssertEqual(left.snapshot("milk")?.quantity, 9)
    }

    func testCrashAfterEverySaveReplaysOneReceiptAndPreservesRecovery() throws {
        for crashPoint in 0...2 {
            var state = try seeded()
            let token = try state.capture(id: "purchase", occurrence: "milk")
            try state.confirm(token)
            if crashPoint >= 1 { try state.publish(token.id) }
            if crashPoint >= 2 { try state.finish(token.id) }
            state = try roundTrip(state)
            try state.confirm(token)
            try state.resume()
            try state.resume()
            XCTAssertEqual(state.receipts.count, 1)
            XCTAssertNil(state.snapshot("milk"))
            XCTAssertFalse(state.isOutstanding("milk"))
            try state.restore(token.id)
            state = try roundTrip(state)
            try state.resume()
            XCTAssertNotNil(state.snapshot("milk"))
            XCTAssertTrue(state.isOutstanding("milk"))
        }
    }

    func testOtherShopperKeepsEntryBuyAnywayDoesNotFulfillReplacementAndUndoIsScoped() throws {
        var alice = try seeded()
        var bob = try seeded("bob")
        try alice.confirm(alice.capture(id: "alice-buy", occurrence: "milk"))
        try alice.resume()
        try bob.merge(alice)
        XCTAssertEqual(bob.snapshot("milk")?.alreadyPurchased, true)
        XCTAssertThrowsError(try bob.capture(id: "bob-buy", occurrence: "milk"))
        try bob.demand(DemandEdit(id: "replacement", occurrence: "milk-again"))
        try bob.confirm(bob.capture(id: "bob-buy", occurrence: "milk", buyAnyway: true))
        try bob.resume()
        XCTAssertTrue(bob.isOutstanding("milk-again"))
        try alice.merge(bob)
        try alice.restore("alice-buy")
        XCTAssertTrue(alice.isPurchased("milk"), "Bob's purchase survives Alice's undo")
        XCTAssertFalse(alice.isOutstanding("milk"))
        XCTAssertThrowsError(try alice.restore("bob-buy"))
        XCTAssertEqual(alice.cartEdits.count, 1, "Bob's private cart never imports")
    }

    func testTwoConcurrentOrdinaryPurchasesKeepDemandFulfilledAfterOneUndo() throws {
        var alice = try seeded()
        var bob = try seeded("bob")
        try alice.confirm(alice.capture(id: "alice-buy", occurrence: "milk"))
        try bob.confirm(bob.capture(id: "bob-buy", occurrence: "milk"))
        try alice.resume()
        try bob.resume()
        try alice.merge(bob)
        try alice.restore("alice-buy")
        XCTAssertFalse(alice.isOutstanding("milk"))
        XCTAssertEqual(alice.snapshot("milk")?.alreadyPurchased, true)
    }

    func testForgedHouseholdRetractionCannotRestorePrivateCart() throws {
        var alice = try seeded()
        try alice.confirm(alice.capture(id: "alice-buy", occurrence: "milk"))
        try alice.resume()
        var bob = try seeded("bob")
        bob.importAdvisoryRetraction("alice-buy")
        try alice.merge(bob)
        XCTAssertNil(alice.snapshot("milk"))
        XCTAssertTrue(alice.privateRestores.isEmpty)
        XCTAssertTrue(alice.isOutstanding("milk"), "Shared writer can corrupt household projection only")
        try alice.restore("alice-buy")
        XCTAssertNotNil(alice.snapshot("milk"))
    }

    func testRestoreNeverRevivesOccurrenceBesideReplacementInEitherDeliveryOrder() throws {
        var buyer = try seeded()
        try buyer.confirm(buyer.capture(id: "purchase", occurrence: "milk"))
        try buyer.resume()
        var replacement = buyer
        try replacement.demand(DemandEdit(id: "d-new", occurrence: "milk-again", replacesOccurrence: "milk"))
        try buyer.restore("purchase")
        for reverse in [false, true] {
            var joined = reverse ? replacement : buyer
            try joined.merge(reverse ? buyer : replacement)
            joined = try roundTrip(joined)
            XCTAssertNil(joined.snapshot("milk"), "Stale recovery cannot recreate old membership")
            XCTAssertFalse(joined.isOutstanding("milk"))
            XCTAssertTrue(joined.isOutstanding("milk-again"))
        }
    }

    func testPermissionPayloadReuseStaleTokensAndPresenceRepair() throws {
        var state = try seeded()
        XCTAssertThrowsError(try state.edit(CartEdit(id: "foreign", owner: "bob", occurrence: "milk",
                                                    generation: "g1", ancestors: [], kind: .remove, quantity: nil)))
        let token = try state.capture(id: "purchase", occurrence: "milk")
        try state.confirm(token)
        let reused = CheckoutIntent(id: token.id, owner: token.owner, occurrence: "eggs",
                                    generation: token.generation, cartEvidence: token.cartEvidence,
                                    demandEvidence: token.demandEvidence, buyAnyway: false)
        XCTAssertThrowsError(try state.confirm(reused))
        let stale = try state.capture(id: "stale", occurrence: "milk")
        try state.edit(CartEdit(id: "q2", owner: "alice", occurrence: "milk", generation: "g1",
                               ancestors: ["a1"], kind: .quantity, quantity: 2))
        XCTAssertThrowsError(try state.confirm(stale))
        XCTAssertTrue(state.republishPresence())
        XCTAssertFalse(state.republishPresence())
        state.damagePresence()
        XCTAssertEqual(state.snapshot("milk")?.quantity, 2)
        XCTAssertTrue(state.republishPresence())
        XCTAssertFalse(state.republishPresence(), "Repair reaches a fixed point")
    }
}
