import CoreData
import XCTest
@testable import Shopping

/// A participant home whose native verification hasn't answered, as on a cached
/// offline session. Going online models a verified session that CloudKit lets write.
final class OfflineParticipantShares: HomeNativeShareSource {
    static let share = HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")
    var online = false

    func identity(for home: Household, in repository: PersonalCartRepository) throws -> HomeNativeAccessIdentity? {
        guard let list = home.groceryList else { throw PersonalCartError.unavailable }
        return HomeNativeAccessIdentity(scope: repository.homeEffectScope(householdID: home.id, listID: list.id),
            storeIdentifier: "participant-store", rootURI: home.objectID.uriRepresentation().absoluteString, share: Self.share)
    }

    func mayPublish(_ home: Household, in repository: PersonalCartRepository) -> Bool { online }
}

/// SHOPPING-273: a participant's own checkout leaves the shopper's own groceries at
/// once, while the household rule still waits for verified publication.
final class ParticipantOwnCheckoutTests: XCTestCase {
    private struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }
    private struct Fixture {
        let persistence: PersistenceController
        let shares: OfflineParticipantShares
        let service: NeedService
        let cart: PersonalCartService
        let session: ShopperSession
        let homeID: UUID
        let listID: UUID
        let needID: UUID
        let url: URL
    }

    private func close(_ persistence: PersistenceController) throws {
        persistence.writer.performAndWait { persistence.writer.reset() }
        persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
    }

    private func open(_ url: URL, session: ShopperSession) throws -> (PersistenceController, OfflineParticipantShares, PersonalCartService) {
        let persistence = try PersistenceController(storeURL: url)
        let shares = OfflineParticipantShares()
        persistence.homeNativeShares = shares
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session))
        return (persistence, shares, cart)
    }

    /// Milk is in the participant's cart, and nothing has been verified natively.
    private func fixture(remembered: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Participant.sqlite")
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.participant",
            environment: "Development", accountRecordName: "participant")
        let (persistence, shares, cart) = try open(url, session: session)
        addTeardownBlock { try self.close(persistence) }
        let service = NeedService(persistence: persistence)
        let home = try service.createHousehold(name: "Shared home")
        let need = remembered
            ? try service.addRememberedNeed(itemID: service.createItem(name: "Milk", householdID: home.householdID),
                                            listID: home.listID, quantity: 2)
            : try service.addOneTimeNeed(title: "Milk", quantity: 2, householdID: home.householdID, listID: home.listID)
        try cart.cart(needID: need, householdID: home.householdID, listID: home.listID)
        return Fixture(persistence: persistence, shares: shares, service: service, cart: cart, session: session,
            homeID: home.householdID, listID: home.listID, needID: need, url: url)
    }

    private func checkout(_ f: Fixture) throws -> PersonalCheckoutOutcome {
        try f.cart.checkout(f.cart.prepareCheckout(tokens: f.cart.entries(householdID: f.homeID, listID: f.listID).map(\.token)))
    }

    private func verify(_ persistence: PersistenceController, _ shares: OfflineParticipantShares, cart: PersonalCartService,
                        homeID: UUID, listID: UUID) throws {
        shares.online = true
        let identity = try cart.transact(save: false) { repository in
            try XCTUnwrap(repository.nativeAccessIdentity(for: repository.household(homeID)))
        }
        XCTAssertTrue(persistence.homeNativeAccess.finish(persistence.homeNativeAccess.begin(identity), access: .writable))
        try cart.resumePending()
    }

    private func purchases(_ cart: PersonalCartService) throws -> Int {
        try cart.transact(save: false) { repository in
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            request.predicate = NSPredicate(format: "kind == %@", "purchase")
            return try repository.context.count(for: request)
        }
    }

    private func householdFulfilled(_ cart: PersonalCartService, homeID: UUID) throws -> Set<UUID> {
        try cart.transact(save: false) { repository in
            try PersonalDemandProjection.fulfilledNeedIDs(householdID: homeID, persistence: cart.persistence,
                in: repository.context, session: repository.session)
        }
    }

    private func groceries(_ f: Fixture) throws -> [UUID] {
        try f.service.groceryNeedProjection(householdID: f.homeID, listID: f.listID, filter: GroceryNeedFilter()).matchingNeedIDs
    }

    func testOfflineCheckoutLeavesOwnGroceriesAcrossRelaunchThenPublishesOnce() throws {
        let f = try fixture()
        XCTAssertEqual(try groceries(f), [f.needID])
        let result = try checkout(f)
        XCTAssertTrue(result.pendingPublication)
        XCTAssertEqual(try purchases(f.cart), 0)
        XCTAssertTrue(try f.cart.entries(householdID: f.homeID, listID: f.listID).isEmpty)
        XCTAssertFalse(try f.cart.outstandingNeedIDs(householdID: f.homeID, listID: f.listID).contains(f.needID))
        XCTAssertEqual(try groceries(f), [])
        XCTAssertFalse(try householdFulfilled(f.cart, homeID: f.homeID).contains(f.needID),
            "The household rule still waits for verified publication")

        try close(f.persistence)
        let (persistence, shares, cart) = try open(f.url, session: f.session)
        addTeardownBlock { try self.close(persistence) }
        XCTAssertFalse(try cart.outstandingNeedIDs(householdID: f.homeID, listID: f.listID).contains(f.needID))
        XCTAssertEqual(try NeedService(persistence: persistence).groceryNeedProjection(householdID: f.homeID,
            listID: f.listID, filter: GroceryNeedFilter()).matchingNeedIDs, [])
        try cart.resumePending()
        XCTAssertEqual(try purchases(cart), 0, "Unverified sessions never publish")
        XCTAssertTrue(try XCTUnwrap(cart.history(householdID: f.homeID, listID: f.listID).first).pendingPublication)

        try verify(persistence, shares, cart: cart, homeID: f.homeID, listID: f.listID)
        try cart.resumePending()
        XCTAssertEqual(try purchases(cart), 1)
        XCTAssertTrue(try householdFulfilled(cart, homeID: f.homeID).contains(f.needID))
        XCTAssertFalse(try cart.outstandingNeedIDs(householdID: f.homeID, listID: f.listID).contains(f.needID))
        XCTAssertEqual(try cart.history(householdID: f.homeID, listID: f.listID).map(\.pendingPublication), [false])
    }

    func testRevocationBeforeVerificationReturnsTheNeedAndKeepsThePrivatePurchase() throws {
        let f = try fixture()
        let result = try checkout(f)
        XCTAssertEqual(try groceries(f), [])
        try f.cart.blockHomeEffects(householdID: f.homeID, listID: f.listID, share: OfflineParticipantShares.share,
            reason: .revoked, operationID: UUID())
        XCTAssertTrue(try f.cart.outstandingNeedIDs(householdID: f.homeID, listID: f.listID).contains(f.needID),
            "The household never learned of the purchase, so the need is outstanding again")
        XCTAssertEqual(try groceries(f), [f.needID])
        let history = try XCTUnwrap(f.cart.history(householdID: f.homeID, listID: f.listID).first)
        XCTAssertEqual(history.id, result.operationID)
        XCTAssertEqual(history.entries.map(\.needID), [f.needID])
        XCTAssertTrue(history.pendingPublication, "The purchase record is retained, unpublished")

        try verify(f.persistence, f.shares, cart: f.cart, homeID: f.homeID, listID: f.listID)
        try f.cart.grantHomeEffects(householdID: f.homeID, listID: f.listID, share: OfflineParticipantShares.share,
            observedBlockIDs: f.cart.homeEffectBoundary(householdID: f.homeID, listID: f.listID), operationID: UUID())
        try f.cart.resumePending()
        XCTAssertEqual(try purchases(f.cart), 0, "A later rejoin never authorizes the earlier checkout")
        XCTAssertEqual(try groceries(f), [f.needID])
        XCTAssertTrue(try XCTUnwrap(f.cart.history(householdID: f.homeID, listID: f.listID).first).pendingPublication)
    }

    func testReadOnlyBeforeVerificationReturnsTheNeedUntilWritableThenPublishesOnce() throws {
        let f = try fixture()
        _ = try checkout(f)
        try f.cart.recordReadOnlyHome(householdID: f.homeID, listID: f.listID, share: OfflineParticipantShares.share,
            operationID: UUID())
        XCTAssertEqual(try groceries(f), [f.needID])
        try f.cart.recordWritableHome(householdID: f.homeID, listID: f.listID, share: OfflineParticipantShares.share,
            observedRestrictionIDs: f.cart.homePermissionBoundary(householdID: f.homeID, listID: f.listID), operationID: UUID())
        XCTAssertEqual(try groceries(f), [])
        try verify(f.persistence, f.shares, cart: f.cart, homeID: f.homeID, listID: f.listID)
        try f.cart.resumePending()
        XCTAssertEqual(try purchases(f.cart), 1)
        XCTAssertEqual(try groceries(f), [])
        XCTAssertTrue(try householdFulfilled(f.cart, homeID: f.homeID).contains(f.needID))
    }

    func testReAddAfterOfflineCheckoutRenewsTheSameNeedAndNeverDuplicates() throws {
        let f = try fixture(remembered: true)
        _ = try checkout(f)
        XCTAssertEqual(try groceries(f), [])
        let catalogItemID = try f.cart.transact(save: false) { repository in
            try XCTUnwrap(repository.need(f.needID, householdID: f.homeID, listID: f.listID)?.item?.id)
        }
        // Dedupe follows the household rule, so the re-add renews the same
        // occurrence, and its new demand evidence returns it to groceries.
        XCTAssertEqual(try f.service.addRememberedNeed(itemID: catalogItemID, listID: f.listID), f.needID)
        XCTAssertEqual(try groceries(f), [f.needID])
        try verify(f.persistence, f.shares, cart: f.cart, homeID: f.homeID, listID: f.listID)
        XCTAssertEqual(try purchases(f.cart), 1)
        XCTAssertFalse(try householdFulfilled(f.cart, homeID: f.homeID).contains(f.needID),
            "The receipt predates the re-add, so it doesn't fulfill the renewed need")
        XCTAssertEqual(try groceries(f), [f.needID])
    }
}
