import CoreData
import XCTest
@testable import Shopping

/// SHOPPING-277: a cart action is complete when it is durable on this device.
/// Presence publication, mirroring contention and verification run afterwards.
@MainActor
final class PersonalCartLocalCommitTests: XCTestCase {
    private struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    private struct Fixture {
        let persistence: PersistenceController
        let needs: NeedService
        let cart: PersonalCartService
        let householdID: UUID
        let listID: UUID
    }

    /// Holds the writer queue after the next writer save, as mirroring export can
    /// hold the shared coordinator between a command's save and its next step.
    private final class WriterHold: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var armed = false
        private var held = 0
        private var observer: NSObjectProtocol?

        init(_ writer: NSManagedObjectContext) {
            observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave,
                object: writer, queue: nil) { [unowned self] _ in
                guard self.lock.withLock({ () -> Bool in
                    guard self.armed else { return false }
                    self.armed = false
                    self.held += 1
                    return true
                }) else { return }
                writer.perform { self.gate.wait() }
            }
        }

        func armAfterNextSave() { lock.withLock { armed = true } }

        func release() {
            let count = lock.withLock { () -> Int in
                defer { held = 0; armed = false }
                return held
            }
            for _ in 0..<count { gate.signal() }
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }

    /// Counts live share lookups. A private command must not need one.
    private final class CountingShares: HomeNativeShareSource, @unchecked Sendable {
        private let lock = NSLock()
        private var lookups = 0
        var count: Int { lock.withLock { lookups } }

        func identity(for home: Household, in repository: PersonalCartRepository) throws -> HomeNativeAccessIdentity? {
            lock.withLock { lookups += 1 }
            return nil
        }

        func requiresVerification(_ home: Household, in repository: PersonalCartRepository) -> Bool { false }

        func mayPublish(_ home: Household, in repository: PersonalCartRepository) -> Bool { true }
    }

    private func fixture(titles: [String]) throws -> (Fixture, [UUID]) {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let ids = try titles.map {
            try needs.addOneTimeNeed(title: $0, householdID: scope.householdID, listID: scope.listID)
        }
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.local-commit-tests", environment: "Development", accountRecordName: "alice"))
        let cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
        return (Fixture(persistence: persistence, needs: needs, cart: cart,
            householdID: scope.householdID, listID: scope.listID), ids)
    }

    private func presenceCount(_ f: Fixture, needID: UUID) throws -> Int {
        try f.cart.transact(save: false) { repository in
            try PersonalCartRepository.sharedValues(HouseholdPresenceEvent.self, kind: "presence",
                householdID: f.householdID, in: repository.context).values.filter { $0.needID == needID }.count
        }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// PersonalCartView's Checkout predicate: only local pending edits disable it.
    private func checkoutEnabled(_ cart: PersonalCartPresentation) -> Bool {
        !cart.entries.isEmpty && !cart.entries.contains {
            cart.isCartTransitionPending($0.needID) || cart.isQuantityTransitionPending($0.id)
        }
    }

    private func removeEnabled(_ cart: PersonalCartPresentation, _ needID: UUID) -> Bool {
        cart.entries.contains { $0.needID == needID } && !cart.isCartTransitionPending(needID)
    }

    /// The writer is held right after each command's private save. Add's receipt
    /// must enable Remove and Checkout, and Remove's receipt must clear the row,
    /// without any later writer transaction: no presence step and no confirming
    /// re-read. Checkout then completes while presence publication is still deferred.
    func testAddRemoveAndCheckoutCompleteWithoutWaitingForPresence() async throws {
        let (f, ids) = try fixture(titles: ["Milk", "Bread"])
        let milk = ids[0], bread = ids[1]
        let presentation = PersonalCartPresentation(service: f.cart, householdID: f.householdID, listID: f.listID,
                                                    presenceDelay: .seconds(3600))
        let loaded = await waitUntil { presentation.hasLoadedSnapshot }
        XCTAssertTrue(loaded)
        let hold = WriterHold(f.persistence.writer)
        defer { hold.release() }

        hold.armAfterNextSave()
        let add = Task { try await presentation.cart(milk) }
        let added = await waitUntil { removeEnabled(presentation, milk) && checkoutEnabled(presentation) }
        XCTAssertTrue(added, "Remove and Checkout wait on a writer transaction after Add's local commit")
        hold.release()
        try await add.value

        hold.armAfterNextSave()
        let entry = try XCTUnwrap(presentation.entries.first { $0.needID == milk })
        let remove = Task { try await presentation.uncart(entry).value }
        let removed = await waitUntil { !presentation.cartedNeedIDs.contains(milk)
            && !presentation.entries.contains { $0.needID == milk } && !presentation.isCartTransitionPending(milk) }
        XCTAssertTrue(removed, "Remove waits on a writer transaction after its local commit")
        hold.release()
        try await remove.value

        try await presentation.cart(bread)
        XCTAssertTrue(removeEnabled(presentation, bread) && checkoutEnabled(presentation),
                      "The returned commit alone enables Remove and Checkout")
        // The receipt's token is the one Checkout captures.
        let receipt = try XCTUnwrap(presentation.entries.first { $0.needID == bread }).token
        let token = try await presentation.prepareCheckout(tokens: [receipt], storeID: nil)
        let outcome = try await presentation.checkout(token, buyAnywayReceiptIDs: [])
        XCTAssertEqual(outcome.purchasedNeedIDs, [bread])
        XCTAssertFalse(presentation.entries.contains { $0.needID == bread }, "Checkout's outcome patches the cart")
        XCTAssertFalse(presentation.outstandingNeedIDs.contains(bread))
        XCTAssertEqual(try presenceCount(f, needID: milk), 0, "Presence is published later, not by the commands")
        XCTAssertEqual(try presenceCount(f, needID: bread), 0)
    }

    /// Deferred presence still converges: the shared publisher runs after its window.
    func testDeferredPresencePublishesAfterTheWindow() async throws {
        let (f, ids) = try fixture(titles: ["Milk"])
        let presentation = PersonalCartPresentation(service: f.cart, householdID: f.householdID, listID: f.listID,
                                                    presenceDelay: .milliseconds(10))
        try await presentation.cart(ids[0])
        let published = await waitUntil { ((try? self.presenceCount(f, needID: ids[0])) ?? 0) > 0 }
        XCTAssertTrue(published)
    }

    /// A home whose effects are blocked settles its dirty presence instead of retrying
    /// on every refresh; resumePending() republishes once access is restored.
    func testBlockedHomePresenceSettlesWithoutPublishing() throws {
        let (f, ids) = try fixture(titles: ["Milk"])
        try f.cart.cart(needID: ids[0], householdID: f.householdID, listID: f.listID, presencePolicy: .deferred)
        try f.cart.blockHomeEffects(householdID: f.householdID, listID: f.listID,
            share: HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner"),
            reason: .left, operationID: UUID())
        XCTAssertEqual(f.cart.republishPresence(each: [ids[0]]), [ids[0]])
        XCTAssertEqual(try presenceCount(f, needID: ids[0]), 0)
    }

    /// A shared record still importing (no identity or payload yet) never fails a
    /// private command; it degrades only the household projection it describes.
    func testHalfImportedSharedRecordsNeverFailAddRemoveOrQuantity() async throws {
        let (f, ids) = try fixture(titles: ["Milk"])
        let context = f.persistence.container.viewContext
        try context.performAndWait {
            let home = try XCTUnwrap(context.fetch(Household.fetchRequest()).first { $0.id == f.householdID })
            for kind in ["purchase", "demand"] {
                let record = HouseholdCartRecord(context: context)
                record.id = PersistenceModel.unsetID
                record.kind = kind
                record.household = home
            }
            try context.save()
        }
        let presentation = PersonalCartPresentation(service: f.cart, householdID: f.householdID, listID: f.listID,
                                                    presenceDelay: .seconds(3600))
        try await presentation.cart(ids[0])
        let entry = try XCTUnwrap(presentation.entries.first { $0.needID == ids[0] })
        try await presentation.setQuantity(3, entry: entry)
        let changed = try XCTUnwrap(presentation.entries.first { $0.needID == ids[0] })
        XCTAssertEqual(changed.quantity, 3)
        try await presentation.uncart(changed).value
        XCTAssertFalse(presentation.entries.contains { $0.needID == ids[0] })
    }

    /// Native identity for a private command comes from the ledger's stored share.
    func testPrivateCommandUsesStoredShareInsteadOfLiveShareLookup() throws {
        let (f, ids) = try fixture(titles: ["Milk", "Bread"])
        let shares = CountingShares()
        f.persistence.homeNativeShares = shares
        let share = HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")
        try f.cart.grantHomeEffects(householdID: f.householdID, listID: f.listID, share: share,
                                    observedBlockIDs: [], operationID: UUID())
        try f.cart.cart(needID: ids[0], householdID: f.householdID, listID: f.listID, presencePolicy: .deferred)
        XCTAssertEqual(shares.count, 0, "A private command never fetches shares")

        let identity = try f.cart.transact(save: false) { repository in
            let home = try repository.household(f.householdID)
            return HomeNativeAccessIdentity(scope: repository.homeEffectScope(householdID: f.householdID, listID: f.listID),
                storeIdentifier: try XCTUnwrap(home.objectID.persistentStore?.identifier),
                rootURI: home.objectID.uriRepresentation().absoluteString, share: share)
        }
        try f.persistence.homeNativeAccess.restrict(f.persistence.homeNativeAccess.begin(identity), to: .readOnly)
        XCTAssertThrowsError(try f.cart.cart(needID: ids[1], householdID: f.householdID, listID: f.listID,
                                             presencePolicy: .deferred)) {
            XCTAssertEqual($0 as? PersonalCartError, .quarantined, "A stored share still finds a read-only observation")
        }
        XCTAssertEqual(shares.count, 0)
    }
}
