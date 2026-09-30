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

    @MainActor
    func testStopSharingReopensDurableTargetsAndRequiresExplicitRetryAfterFailedSubmission() async throws {
        let lifetime = SQLiteTestFixtureLifetime()
        addTeardownBlock { try lifetime.cleanup() }
        let directory = try lifetime.makeDirectory()
        let url = directory.appendingPathComponent("Private.sqlite")
        let journalURL = directory.appendingPathComponent("invitation.json")
        let persistence = lifetime.own(try PersistenceController(storeURL: url))
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.stop-ledger",
            environment: "Development", accountRecordName: "owner")
        let service = NeedService(persistence: persistence)
        let first = try service.createHousehold(name: "Owner home")
        let other = try service.createHousehold(name: "Other home")
        let homes = try HomeDiscoveryService(persistence: persistence).discover().homes
        let home = try XCTUnwrap(homes.first { $0.graph.householdID == first.householdID })
        let otherHome = try XCTUnwrap(homes.first { $0.graph.householdID == other.householdID })
        let scope = ActiveHomeScope(session: session, graph: home.graph)
        let otherScope = ActiveHomeScope(session: session, graph: otherHome.graph)
        let needID = try service.addOneTimeNeed(title: "Retained groceries", quantity: 2,
            householdID: first.householdID, listID: first.listID)
        let otherNeedID = try service.addOneTimeNeed(title: "Other groceries", quantity: 3,
            householdID: other.householdID, listID: other.listID)
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session))
        try cart.cart(needID: needID, householdID: first.householdID, listID: first.listID)
        try cart.cart(needID: otherNeedID, householdID: other.householdID, listID: other.listID)
        let beforeCart = try cart.entries(householdID: first.householdID, listID: first.listID)
        let beforeOtherCart = try cart.entries(householdID: other.householdID, listID: other.listID)
        let otherRemoval = HomeMembershipRemoval(id: UUID(), origin: otherScope,
            share: MembershipTransportDouble.share, ownerParticipantID: "owner",
            participantIDs: ["other-friend"], cancelledInvitationID: nil, purpose: .removeMember, confirmedAt: Date())
        try cart.retainHomeMemberRemoval(otherRemoval)
        let native = MembershipTransportDouble(scope: scope, journalURL: journalURL)
        await native.include("accepted", acceptance: .accepted)
        await native.include("pending", acceptance: .pending)
        let transport = SQLiteRemovalTransport(cart: cart, native: native, interruptAfterRetention: true)
        let coordinator = HomeMembershipCoordinator()
        let confirmation = try await coordinator.prepareRemoval(purpose: .stopSharing,
            scope: scope, journalURL: journalURL, transport: transport)
        XCTAssertEqual(confirmation.removal.participantIDs, ["accepted", "pending"])
        do {
            _ = try await coordinator.confirmRemoval(confirmation, scope: scope,
                journalURL: journalURL, transport: transport)
            XCTFail("The injected interruption must stop after the durable private write")
        } catch { XCTAssertEqual(error as? SQLiteRemovalTransport.Interruption, .afterRetention) }
        XCTAssertEqual(try cart.retainedHomeMemberRemovals(scope: scope, share: MembershipTransportDouble.share),
            [confirmation.removal])
        let beforeSubmissions = await native.removedParticipants
        XCTAssertTrue(beforeSubmissions.isEmpty)
        XCTAssertTrue(try HomeInviteJournal(url: journalURL).removals(scope: scope).isEmpty,
            "Recovery must come from the SQLite handoff, not a preseeded journal")
        try close(persistence)

        let reopened = lifetime.own(try PersistenceController(storeURL: url))
        let reopenedCart = PersonalCartService(persistence: reopened, sessionProvider: Provider(session: session))
        let recoveredTransport = SQLiteRemovalTransport(cart: reopenedCart, native: native)
        let recoveredCoordinator = HomeMembershipCoordinator()
        await native.include("later", acceptance: .pending)
        await native.setRemovalMode(.fail)
        do {
            _ = try await recoveredCoordinator.refresh(scope: scope, journalURL: journalURL, transport: recoveredTransport)
            XCTFail("The first recovered submission is deliberately unsuccessful")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .shareUnavailable) }
        await native.setRemovalMode(.succeed)
        let waiting = try await HomeMembershipCoordinator().refresh(scope: scope,
            journalURL: journalURL, transport: recoveredTransport)
        XCTAssertEqual(waiting.removals.map(\.removal), [confirmation.removal])
        XCTAssertTrue(try XCTUnwrap(waiting.removals.first).requiresRetry)
        XCTAssertEqual(Set(waiting.members.map(\.id)), ["owner", "accepted", "pending", "later"])
        let beforeRetry = await native.removedParticipants
        XCTAssertEqual(beforeRetry, [["accepted", "pending"]], "Passive refresh must not retry an uncertain submission")
        let completed = try await recoveredCoordinator.retryRemovals(scope: scope,
            journalURL: journalURL, transport: recoveredTransport)
        XCTAssertEqual(Set(completed.members.map(\.id)), ["owner", "later"])
        XCTAssertNotNil(try XCTUnwrap(completed.removals.first).absentObservedAt)
        XCTAssertEqual(completed.removals.map(\.removal), [confirmation.removal])
        let submitted = await native.removedParticipants
        XCTAssertEqual(submitted, [["accepted", "pending"], ["accepted", "pending"]])
        let counts = await native.counts()
        XCTAssertEqual(counts.created, 0)
        XCTAssertEqual(counts.added, 0)
        XCTAssertEqual(counts.urls, 0)
        XCTAssertEqual(try reopenedCart.retainedHomeMemberRemovals(scope: otherScope, share: MembershipTransportDouble.share), [otherRemoval])
        XCTAssertEqual(try reopenedCart.entries(householdID: first.householdID, listID: first.listID), beforeCart)
        XCTAssertEqual(try reopenedCart.entries(householdID: other.householdID, listID: other.listID), beforeOtherCart)
        let context = lifetime.own(reopened.simulationContext())
        try context.performAndWait {
            XCTAssertEqual(Set(try context.fetch(Household.fetchRequest()).compactMap(\.id)), [first.householdID, other.householdID])
            XCTAssertEqual(Set(try context.fetch(Need.fetchRequest()).compactMap(\.id)), [needID, otherNeedID])
            let records = try context.fetch(NSFetchRequest<PersonalCartRecord>(entityName: "PersonalCartRecord"))
            XCTAssertFalse(records.isEmpty)
            XCTAssertTrue(records.allSatisfy { $0.objectID.persistentStore == reopened.primaryStore })
            XCTAssertTrue(records.allSatisfy { ShareAssociationScope.household(for: $0) == nil })
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

/// Only native membership is simulated. Retention and reconstruction use the real
/// private SQLite ledger, with a failure at its completed-write handoff boundary.
private actor SQLiteRemovalTransport: HomeMembershipTransport {
    enum Interruption: Error, Equatable { case afterRetention }
    private let cart: PersonalCartService
    private let native: MembershipTransportDouble
    private let interruptAfterRetention: Bool

    init(cart: PersonalCartService, native: MembershipTransportDouble, interruptAfterRetention: Bool = false) {
        self.cart = cart
        self.native = native
        self.interruptAfterRetention = interruptAfterRetention
    }

    func refresh(scope: ActiveHomeScope) async throws -> HomeMembershipSnapshot {
        try await native.refresh(scope: scope)
    }
    func makeInvitationParticipant(scope: ActiveHomeScope) async throws -> HomeInviteMaterial {
        try await native.makeInvitationParticipant(scope: scope)
    }
    func addInvitation(_ material: HomeInviteMaterial, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot {
        try await native.addInvitation(material, expected: expected)
    }
    func invitationURL(participantID: String, scope: ActiveHomeScope, share: HomeShareIdentity) async throws -> URL {
        try await native.invitationURL(participantID: participantID, scope: scope, share: share)
    }
    func retainedRemovals(scope: ActiveHomeScope, share: HomeShareIdentity) async throws -> [HomeMembershipRemoval] {
        try cart.retainedHomeMemberRemovals(scope: scope, share: share)
    }
    func retainRemoval(_ removal: HomeMembershipRemoval, scope: ActiveHomeScope) async throws {
        guard removal.origin == scope else { throw HomeMembershipError.scopeChanged }
        try cart.retainHomeMemberRemoval(removal)
        if interruptAfterRetention { throw Interruption.afterRetention }
    }
    func removeParticipants(_ participantIDs: Set<String>, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot {
        try await native.removeParticipants(participantIDs, expected: expected)
    }
}
