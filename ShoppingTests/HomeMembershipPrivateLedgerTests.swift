import CoreData
import XCTest
@testable import Shopping

final class HomeMembershipPrivateLedgerTests: XCTestCase {
    private struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    private func close(_ persistence: PersistenceController) throws {
        persistence.writer.performAndWait { persistence.writer.reset() }
        persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
    }

    func testRemovalSurvivesReopenInPrivateLedgerWithoutChangingHouseholdOrCart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Private.sqlite")
        let persistence = try PersistenceController(storeURL: url)
        addTeardownBlock { try self.close(persistence) }
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.removal-ledger",
            environment: "Development", accountRecordName: "owner")
        let service = NeedService(persistence: persistence)
        _ = try service.createHousehold(name: "Original home")
        let home = try XCTUnwrap(HomeDiscoveryService(persistence: persistence).discover().homes.first)
        let scope = ActiveHomeScope(session: session, graph: home.graph)
        _ = try service.createPerson(name: "Assignee", householdID: home.graph.householdID)
        let needID = try service.addOneTimeNeed(title: "Private cart", quantity: 2,
            householdID: home.graph.householdID, listID: home.graph.listID)
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session))
        try cart.cart(needID: needID, householdID: home.graph.householdID, listID: home.graph.listID)
        let before = try cart.entries(householdID: home.graph.householdID, listID: home.graph.listID)
        let share = MembershipTransportDouble.share
        let removal = HomeMembershipRemoval(id: UUID(), origin: scope, share: share, ownerParticipantID: "owner",
            participantIDs: ["friend"], cancelledInvitationID: nil, purpose: .removeMember, confirmedAt: Date())
        try cart.retainHomeMemberRemoval(removal)
        try cart.retainHomeMemberRemoval(removal)
        XCTAssertEqual(try cart.retainedHomeMemberRemovals(scope: scope, share: share), [removal])
        let context = persistence.container.newBackgroundContext()
        try context.performAndWait {
            let records = try context.fetch(NSFetchRequest<PersonalCartRecord>(entityName: "PersonalCartRecord"))
                .filter { $0.kind == "homeMemberRemoval" }
            XCTAssertEqual(records.count, 1)
            XCTAssertTrue(records[0].entity.relationshipsByName.isEmpty)
            XCTAssertEqual(records[0].objectID.persistentStore, persistence.primaryStore)
            XCTAssertEqual(try context.fetch(Person.fetchRequest()).map(\.name), ["Assignee"])
            XCTAssertEqual(try context.fetch(Household.fetchRequest()).map(\.name), ["Original home"])
            context.reset()
        }
        XCTAssertEqual(try cart.entries(householdID: home.graph.householdID, listID: home.graph.listID), before)
        try close(persistence)
        let reopened = try PersistenceController(storeURL: url)
        addTeardownBlock { try self.close(reopened) }
        let reopenedCart = PersonalCartService(persistence: reopened, sessionProvider: Provider(session: session))
        XCTAssertEqual(try reopenedCart.retainedHomeMemberRemovals(scope: scope, share: share), [removal])
        XCTAssertEqual(try reopenedCart.entries(householdID: home.graph.householdID, listID: home.graph.listID), before)
        let changed = HomeMembershipRemoval(id: removal.id, origin: scope, share: share, ownerParticipantID: "owner",
            participantIDs: ["someone-else"], cancelledInvitationID: nil, purpose: .removeMember, confirmedAt: removal.confirmedAt)
        XCTAssertThrowsError(try reopenedCart.retainHomeMemberRemoval(changed)) {
            XCTAssertEqual($0 as? PersonalCartError, .reusedOperationID)
        }
        XCTAssertEqual(try reopenedCart.retainedHomeMemberRemovals(scope: scope, share: share), [removal])
        let otherSession = try ShopperSession.authenticated(containerIdentifier: session.containerIdentifier,
            environment: session.environment, accountRecordName: "other")
        let otherCart = PersonalCartService(persistence: reopened, sessionProvider: Provider(session: otherSession))
        XCTAssertThrowsError(try otherCart.retainHomeMemberRemoval(removal)) {
            XCTAssertEqual($0 as? HomeMembershipError, .scopeChanged)
        }
    }

    func testPortableAuthorizationMatchesLogicalHomeAcrossDevicesButNotOtherHomeOrShare() throws {
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.removal-ledger",
            environment: "Development", accountRecordName: "owner")
        let homeID = UUID(), listID = UUID()
        let original = ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "phone-one",
            rootURI: "x-coredata://one/root", householdID: homeID, listID: listID))
        let otherDevice = ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "phone-two",
            rootURI: "x-coredata://two/root", householdID: homeID, listID: listID))
        let otherHome = ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "phone-one",
            rootURI: "x-coredata://one/other", householdID: UUID(), listID: UUID()))
        let share = MembershipTransportDouble.share
        let removal = HomeMembershipRemoval(id: UUID(), origin: original, share: share, ownerParticipantID: "owner",
            participantIDs: ["friend"], cancelledInvitationID: nil, purpose: .removeMember, confirmedAt: Date())
        XCTAssertTrue(removal.matches(scope: otherDevice, share: share))
        XCTAssertFalse(removal.matches(scope: otherHome, share: share))
        XCTAssertFalse(removal.matches(scope: original, share: HomeShareIdentity(recordName: "another",
            zoneName: share.zoneName, zoneOwnerName: share.zoneOwnerName)))
    }
}
