import CoreData
import XCTest
@testable import Shopping

/// A participant home whose native verification waits, as it can behind CloudKit
/// mirroring, until the test releases it. Bounded so a regression fails, not hangs.
private final class HeldVerificationShares: HomeNativeShareSource, @unchecked Sendable {
    private let lock = NSLock()
    private var held: DispatchSemaphore?

    func hold() { lock.withLock { held = DispatchSemaphore(value: 0) } }

    func release() {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            defer { held = nil }
            return held
        }
        semaphore?.signal()
    }

    func identity(for home: Household, in repository: PersonalCartRepository) throws -> HomeNativeAccessIdentity? {
        try OfflineParticipantShares().identity(for: home, in: repository)
    }

    func requiresVerification(_ home: Household, in repository: PersonalCartRepository) -> Bool { true }

    func mayPublish(_ home: Household, in repository: PersonalCartRepository) -> Bool {
        _ = lock.withLock { held }?.wait(timeout: .now() + 3)
        return true
    }
}

/// Checkout depends only on local durable state, for an owned home and for a
/// participant home (SHOPPING-285, SHOPPING-287).
final class LocalCheckoutTests: XCTestCase {
    private struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }
    private enum Role { case owner, participant }
    private struct Fixture {
        let persistence: PersistenceController
        let cart: PersonalCartService
        let homeID: UUID
        let listID: UUID
        let needIDs: [String: UUID]
        let url: URL
    }

    private func close(_ persistence: PersistenceController) throws {
        persistence.writer.performAndWait { persistence.writer.reset() }
        persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
    }

    private static let session = try! ShopperSession.authenticated(containerIdentifier: "iCloud.test.checkout",
        environment: "Development", accountRecordName: "shopper")

    private func open(_ url: URL) throws -> (PersistenceController, PersonalCartService) {
        let persistence = try PersistenceController(storeURL: url)
        addTeardownBlock { try self.close(persistence) }
        return (persistence, PersonalCartService(persistence: persistence, sessionProvider: Provider(session: Self.session)))
    }

    private func verify(_ persistence: PersistenceController, cart: PersonalCartService, homeID: UUID) throws {
        let identity = try cart.transact(save: false) { repository in
            try XCTUnwrap(repository.nativeAccessIdentity(for: repository.household(homeID)))
        }
        XCTAssertTrue(persistence.homeNativeAccess.finish(persistence.homeNativeAccess.begin(identity), access: .writable))
    }

    /// Milk is in the cart and Bread is not. A participant home is natively verified
    /// writable unless `verified` is false.
    private func fixture(_ role: Role, verified: Bool = true,
                         shares: (any HomeNativeShareSource)? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Checkout.sqlite")
        let (persistence, cart) = try open(url)
        let service = NeedService(persistence: persistence)
        let home = try service.createHousehold(name: "Home")
        var needIDs: [String: UUID] = [:]
        for title in ["Milk", "Bread"] {
            needIDs[title] = try service.addOneTimeNeed(title: title, quantity: nil,
                householdID: home.householdID, listID: home.listID)
        }
        if role == .participant {
            let offline = OfflineParticipantShares()
            offline.online = verified
            persistence.homeNativeShares = shares ?? offline
            if verified { try verify(persistence, cart: cart, homeID: home.householdID) }
        }
        try cart.cart(needID: try XCTUnwrap(needIDs["Milk"]), householdID: home.householdID, listID: home.listID)
        return Fixture(persistence: persistence, cart: cart, homeID: home.householdID, listID: home.listID,
                       needIDs: needIDs, url: url)
    }

    /// Another device's purchase receipt whose payload hasn't imported yet.
    private func importHalfReceipt(_ f: Fixture, id: UUID) throws {
        let context = f.persistence.container.viewContext
        try context.performAndWait {
            let record = HouseholdCartRecord(context: context)
            record.id = id
            record.kind = "purchase"
            record.household = try XCTUnwrap(context.fetch(Household.fetchRequest()).first { $0.id == f.homeID })
            try context.save()
        }
    }

    private func finishImport(_ f: Fixture, receipt: HouseholdPurchaseEvent) throws {
        let context = f.persistence.container.viewContext
        try context.performAndWait {
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            request.predicate = NSPredicate(format: "id == %@", receipt.id as CVarArg)
            try XCTUnwrap(context.fetch(request).first).payload = try PersonalCartCoding.encode(receipt)
            try context.save()
        }
    }

    private func ownPurchases(_ f: Fixture) throws -> Int {
        try f.cart.transact(save: false) { repository in
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            request.predicate = NSPredicate(format: "kind == %@ AND payload != nil", "purchase")
            return try repository.context.fetch(request).filter {
                try PersonalCartCoding.decode(HouseholdPurchaseEvent.self, $0.payload).shopperID == repository.session.shopperID
            }.count
        }
    }

    /// Read on the view context, so a writer held by publication can't delay it.
    private func householdRecords(_ persistence: PersistenceController, kind: String) throws -> Int {
        let context = persistence.container.viewContext
        return try context.performAndWait {
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            request.predicate = NSPredicate(format: "kind == %@ AND payload != nil", kind)
            return try context.count(for: request)
        }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try condition()
    }

    private func publication(_ f: Fixture, cart: PersonalCartService? = nil) throws -> PersonalPublicationState? {
        try (cart ?? f.cart).history(householdID: f.homeID, listID: f.listID).first?.publication
    }

    private func prepare(_ f: Fixture) throws -> PersonalCheckoutToken {
        try f.cart.prepareCheckout(tokens: f.cart.entries(householdID: f.homeID, listID: f.listID).map(\.token))
    }

    // MARK: - SHOPPING-285: half-imported household receipts

    func testHalfImportedReceiptForAnUnrelatedNeedNeverBlocksOwnerCheckout() throws {
        try assertUnrelatedHalfReceiptCheckout(.owner)
    }

    func testHalfImportedReceiptForAnUnrelatedNeedNeverBlocksParticipantCheckout() throws {
        try assertUnrelatedHalfReceiptCheckout(.participant)
    }

    func testHalfImportedReceiptForACartedNeedStillRequiresBuyAnywayForOwner() throws {
        try assertCartedHalfReceiptCheckout(.owner)
    }

    func testHalfImportedReceiptForACartedNeedStillRequiresBuyAnywayForParticipant() throws {
        try assertCartedHalfReceiptCheckout(.participant)
    }

    /// Bread's receipt from another shopper is still importing, with or without its
    /// identity. Milk's checkout proceeds and publishes once.
    private func assertUnrelatedHalfReceiptCheckout(_ role: Role) throws {
        let f = try fixture(role)
        let bread = try XCTUnwrap(f.needIDs["Bread"]), milk = try XCTUnwrap(f.needIDs["Milk"])
        try importHalfReceipt(f, id: PersonalCartCoding.stableID("purchase", UUID().uuidString, bread.uuidString))
        try importHalfReceipt(f, id: PersistenceModel.unsetID)
        let entry = try XCTUnwrap(f.cart.entries(householdID: f.homeID, listID: f.listID).first)
        XCTAssertEqual(entry.needID, milk)
        XCTAssertTrue(entry.purchaseNotices.isEmpty)
        let outcome = try f.cart.checkout(prepare(f))
        XCTAssertEqual(outcome.purchasedNeedIDs, [milk])
        XCTAssertFalse(outcome.pendingPublication)
        XCTAssertEqual(try ownPurchases(f), 1)
        XCTAssertTrue(try f.cart.entries(householdID: f.homeID, listID: f.listID).isEmpty)
    }

    /// A receipt that will concern Milk carries no readable subject until its payload
    /// arrives, so it is treated as still in transit (ADR 0002). Once it arrives, the
    /// captured checkout skips Milk and only an explicit Buy anyway purchases it.
    private func assertCartedHalfReceiptCheckout(_ role: Role) throws {
        let f = try fixture(role)
        let milk = try XCTUnwrap(f.needIDs["Milk"])
        let otherCheckout = UUID()
        let receiptID = PersonalCartCoding.stableID("purchase", otherCheckout.uuidString, milk.uuidString)
        try importHalfReceipt(f, id: receiptID)
        let captured = try prepare(f)
        XCTAssertTrue(try XCTUnwrap(captured.captures.first).entry.purchaseNotices.isEmpty)

        try finishImport(f, receipt: HouseholdPurchaseEvent(id: receiptID, checkoutID: otherCheckout, shopperID: UUID(),
            householdID: f.homeID, listID: f.listID, capture: try XCTUnwrap(captured.captures.first)))
        let skipped = try f.cart.checkout(captured)
        XCTAssertEqual(skipped.purchasedNeedIDs, [])
        XCTAssertEqual(skipped.skippedNeedIDs, [milk], "A newly arrived notice needs explicit agreement")
        let noticed = try XCTUnwrap(f.cart.entries(householdID: f.homeID, listID: f.listID).first)
        XCTAssertEqual(noticed.purchaseNotices.map(\.receiptID), [receiptID])

        let bought = try f.cart.checkout(prepare(f), buyAnywayReceiptIDs: [receiptID])
        XCTAssertEqual(bought.purchasedNeedIDs, [milk])
        XCTAssertEqual(try ownPurchases(f), 1)
    }

    // MARK: - SHOPPING-287: household publication runs after the command returns

    /// Native verification is held, as behind CloudKit mirroring. Checkout and Restore
    /// return once their private intents are saved; each household record is written
    /// exactly once after verification answers.
    @MainActor
    func testCheckoutAndRestoreReturnBeforeHeldVerificationThenPublishOnce() async throws {
        let shares = HeldVerificationShares()
        let f = try fixture(.participant, shares: shares)
        let presentation = PersonalCartPresentation(service: f.cart, householdID: f.homeID, listID: f.listID,
                                                    presenceDelay: .seconds(3600))
        let token = try prepare(f)
        shares.hold()
        let started = ContinuousClock.now
        let outcome = try await presentation.checkout(token, buyAnywayReceiptIDs: [])
        print("SHOPPING-287 checkout returned after \(ContinuousClock.now - started)")
        XCTAssertEqual(try householdRecords(f.persistence, kind: "purchase"), 0, "Checkout returned before publication")
        XCTAssertEqual(outcome.purchasedNeedIDs, [try XCTUnwrap(f.needIDs["Milk"])])
        XCTAssertFalse(outcome.pendingPublication, "A verified home's publication is not held")
        shares.release()
        let published = try await waitUntil { try self.householdRecords(f.persistence, kind: "purchase") == 1 }
        XCTAssertTrue(published)

        shares.hold()
        let restored = try await presentation.restore(checkoutID: outcome.operationID)
        XCTAssertEqual(try householdRecords(f.persistence, kind: "retraction"), 0, "Restore returned before publication")
        XCTAssertFalse(restored.pendingPublication)
        shares.release()
        let retracted = try await waitUntil { try self.householdRecords(f.persistence, kind: "retraction") == 1 }
        XCTAssertTrue(retracted)
        try f.cart.resumePending()
        try f.cart.resumePending()
        XCTAssertEqual(try householdRecords(f.persistence, kind: "purchase"), 1)
        XCTAssertEqual(try householdRecords(f.persistence, kind: "retraction"), 1)
    }

    /// An owned home needs no native verification: the outbox publishes each record once.
    @MainActor
    func testOwnerDeferredCheckoutAndRestorePublishOnceFromTheOutbox() async throws {
        let f = try fixture(.owner)
        let presentation = PersonalCartPresentation(service: f.cart, householdID: f.homeID, listID: f.listID,
                                                    presenceDelay: .seconds(3600))
        let outcome = try await presentation.checkout(try prepare(f), buyAnywayReceiptIDs: [])
        XCTAssertFalse(outcome.pendingPublication)
        let published = try await waitUntil { try self.publication(f) == .published }
        XCTAssertTrue(published)
        let restored = try await presentation.restore(checkoutID: outcome.operationID)
        XCTAssertFalse(restored.pendingPublication)
        let retracted = try await waitUntil { try self.householdRecords(f.persistence, kind: "retraction") == 1 }
        XCTAssertTrue(retracted)
        try f.cart.resumePending()
        XCTAssertEqual(try householdRecords(f.persistence, kind: "purchase"), 1)
        XCTAssertEqual(try householdRecords(f.persistence, kind: "retraction"), 1)
        XCTAssertEqual(try publication(f), .published)
    }

    /// An unverified participant's checkout reports the household update as held, as
    /// before (the Watch says "Household update will sync later"). A relaunch whose
    /// verification succeeds resumes it, and it publishes once.
    @MainActor
    func testHeldCheckoutReportsPendingAndRelaunchPublishesOnce() async throws {
        let f = try fixture(.participant, verified: false)
        let presentation = PersonalCartPresentation(service: f.cart, householdID: f.homeID, listID: f.listID,
                                                    presenceDelay: .seconds(3600))
        let outcome = try await presentation.checkout(try prepare(f), buyAnywayReceiptIDs: [])
        XCTAssertTrue(outcome.pendingPublication)
        XCTAssertEqual(try publication(f), .held)
        XCTAssertEqual(try householdRecords(f.persistence, kind: "purchase"), 0)

        let (persistence, cart) = try open(f.url)
        let shares = OfflineParticipantShares()
        shares.online = true
        persistence.homeNativeShares = shares
        XCTAssertEqual(try publication(f, cart: cart), .held)
        try verify(persistence, cart: cart, homeID: f.homeID)
        XCTAssertEqual(try publication(f, cart: cart), .pending)
        try cart.resumePending()
        try cart.resumePending()
        XCTAssertEqual(try householdRecords(persistence, kind: "purchase"), 1)
        XCTAssertEqual(try publication(f, cart: cart), .published)
    }

    /// The UI authority that saved the intent may retire before the outbox runs, as
    /// when the shopper switches home. Publication still completes.
    @MainActor
    func testDeferredPublicationOutlivesTheRetiredCommandAuthority() async throws {
        let shares = HeldVerificationShares()
        let f = try fixture(.participant, shares: shares)
        let authority = UICommandAuthority()
        let presentation = PersonalCartPresentation(service: f.cart.scoped(to: authority), householdID: f.homeID,
                                                    listID: f.listID, presenceDelay: .seconds(3600))
        let token = try prepare(f)
        shares.hold()
        _ = try await presentation.checkout(token, buyAnywayReceiptIDs: [])
        authority.retire()
        shares.release()
        let published = try await waitUntil { try self.householdRecords(f.persistence, kind: "purchase") == 1 }
        XCTAssertTrue(published)
        let completed = try await waitUntil { try self.publication(f) == .published }
        XCTAssertTrue(completed)
    }

    // MARK: - SHOPPING-291: restore without waiting for its retraction

    /// The shopper's own published receipt never reads as a purchase notice on the
    /// restored entry while its retraction still waits in the outbox.
    func testRestoredEntryShowsNoPurchaseNoticeBeforeItsRetractionPublishes() async throws {
        let f = try fixture(.owner)
        let milk = try XCTUnwrap(f.needIDs["Milk"])
        let checkout = try f.cart.checkout(try prepare(f))
        XCTAssertEqual(try householdRecords(f.persistence, kind: "purchase"), 1)
        // Occupy the serial outbox so the restore's retraction waits behind it.
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        f.cart.checkoutPublication.request { started.signal(); release.wait() }
        started.wait()
        defer { release.signal() }
        _ = try f.cart.restore(checkoutID: checkout.operationID, effects: .deferred)
        XCTAssertEqual(try householdRecords(f.persistence, kind: "retraction"), 0)
        let restored = try XCTUnwrap(f.cart.entries(householdID: f.homeID, listID: f.listID).first { $0.needID == milk })
        XCTAssertEqual(restored.purchaseNotices, [], "Only another shopper's purchase is a notice")
        release.signal()
        let retracted = try await waitUntil { try self.householdRecords(f.persistence, kind: "retraction") == 1 }
        XCTAssertTrue(retracted)
        let settled = try XCTUnwrap(f.cart.entries(householdID: f.homeID, listID: f.listID).first { $0.needID == milk })
        XCTAssertEqual(settled.purchaseNotices, [])
    }
}
