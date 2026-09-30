import CoreData
import XCTest
@testable import Shopping

final class ManagedHomeLeaveTransportTests: XCTestCase {
    private enum Failure: Error { case native, zoneUnavailable }

    private final class Provider: ShopperSessionProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var session: ShopperSession
        init(_ session: ShopperSession) { self.session = session }
        func currentSession() throws -> ShopperSession { lock.withLock { session } }
        func replace(with session: ShopperSession) { lock.withLock { self.session = session } }
    }

    /// Only the platform lookup and callback are simulated. The transport owns
    /// graph checks, zone serialization, private commits and completion evidence.
    private final class Backend: HomeLeaveBackend, @unchecked Sendable {
        let persistence: PersistenceController
        let provider: Provider
        let session: ShopperSession
        let identity: HomeNativeAccessIdentity
        private let lock = NSLock()
        private var count = 0
        var membershipValue: HomeLeaveMembership
        var membershipAction: @Sendable () async throws -> Void = {}
        var mappingAction: @Sendable (PersonalCartRepository) throws -> Void = { _ in }
        var purgeAction: @Sendable (HomeLeaveCommand) async throws -> HomeLeaveZone
        var zoneAction: @Sendable (HomeLeaveCommand) async throws -> Bool = { _ in true }

        init(persistence: PersistenceController, provider: Provider, session: ShopperSession, identity: HomeNativeAccessIdentity) {
            self.persistence = persistence; self.provider = provider
            self.session = session; self.identity = identity
            membershipValue = Self.membership(identity)
            purgeAction = { HomeLeaveZone(share: $0.origin.share) }
        }

        static func membership(_ identity: HomeNativeAccessIdentity, participantID: String = "participant",
            role: HomeLeaveMembership.Participant.Role = .privateUser,
            acceptance: HomeLeaveMembership.Participant.Acceptance = .accepted,
            permission: HomeLeaveMembership.Participant.Permission = .readWrite,
            privateShare: Bool = true) -> HomeLeaveMembership {
            HomeLeaveMembership(share: identity.share, isPrivateShare: privateShare,
                currentParticipant: .init(id: participantID, role: role, acceptance: acceptance, permission: permission),
                privateParticipantIDs: [participantID])
        }

        var purgeCount: Int { lock.withLock { count } }

        func validateEnvironment(identity: HomeNativeAccessIdentity, storeURL: URL?) throws -> ShopperSession {
            guard try provider.currentSession() == session else { throw PersonalCartError.accountChanged }
            guard identity == self.identity, let store = persistence.primaryStore,
                  store.identifier == identity.storeIdentifier,
                  persistence.container.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
                  storeURL == nil || store.url?.standardizedFileURL == storeURL?.standardizedFileURL else {
                throw PersonalCartError.scopeChanged
            }
            return session
        }

        func validateMapping(identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws {
            guard identity == self.identity, repository.persistence === persistence,
                  repository.session == session else { throw PersonalCartError.scopeChanged }
            try mappingAction(repository)
        }

        func membership(identity: HomeNativeAccessIdentity) async throws -> HomeLeaveMembership {
            guard identity == self.identity else { throw PersonalCartError.scopeChanged }
            try await membershipAction()
            return membershipValue
        }

        func purge(_ command: HomeLeaveCommand, storeIdentity: ObjectIdentifier) async throws -> HomeLeaveZone {
            guard let store = persistence.primaryStore, ObjectIdentifier(store) == storeIdentity,
                  command.origin == identity else { throw PersonalCartError.scopeChanged }
            lock.withLock { count += 1 }
            return try await purgeAction(command)
        }

        func zoneExists(_ command: HomeLeaveCommand) async throws -> Bool { try await zoneAction(command) }
    }

    private actor HeldCallback {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func hold(started: @Sendable () -> Void) async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0; started() }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private struct Fixture {
        let persistence: PersistenceController
        let cart: PersonalCartService
        let provider: Provider
        let identity: HomeNativeAccessIdentity
        let backend: Backend
        var transport: ManagedHomeLeaveTransport {
            ManagedHomeLeaveTransport(cart: cart, persistence: persistence, backend: backend)
        }
    }

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
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let persistence = try PersistenceController(storeURL: directory.appendingPathComponent("Leave.sqlite"))
        addTeardownBlock { try self.close(persistence) }
        let needs = NeedService(persistence: persistence)
        let home = try needs.createHousehold(name: "Shared home")
        let bought = try needs.addOneTimeNeed(title: "Bought milk", quantity: 1, householdID: home.householdID, listID: home.listID)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.native-leave",
            environment: "Development", accountRecordName: "participant")
        let provider = Provider(session)
        let cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
        try cart.cart(needID: bought, householdID: home.householdID, listID: home.listID)
        let checkout = try cart.prepareCheckout(tokens: cart.entries(householdID: home.householdID, listID: home.listID).map(\.token))
        _ = try cart.checkout(checkout, operationID: UUID())
        let pending = try needs.addOneTimeNeed(title: "Retained bananas", quantity: 2, householdID: home.householdID, listID: home.listID)
        try cart.cart(needID: pending, householdID: home.householdID, listID: home.listID)
        let graph = try XCTUnwrap(HomeDiscoveryService(persistence: persistence).discover().homes.first?.graph)
        let identity = HomeNativeAccessIdentity(scope: HomeEffectScope(session: session, householdID: home.householdID, listID: home.listID),
            storeIdentifier: graph.storeIdentifier, rootURI: graph.rootURI,
            share: HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner"))
        let backend = Backend(persistence: persistence, provider: provider, session: session, identity: identity)
        return Fixture(persistence: persistence, cart: cart, provider: provider, identity: identity, backend: backend)
    }

    private static func deleteGraph(_ f: Fixture, keepList: Bool = false) throws {
        let context = f.persistence.container.newBackgroundContext()
        try context.performAndWait {
            defer { context.reset() }
            let homes = try context.fetch(Household.fetchRequest())
            for home in homes where home.id == f.identity.scope.householdID {
                if keepList { home.groceryList?.household = nil; home.groceryList = nil }
                context.delete(home)
            }
            if !keepList {
                for list in try context.fetch(GroceryList.fetchRequest()) where list.id == f.identity.scope.listID {
                    context.delete(list)
                }
            }
            try context.save()
        }
    }

    private static func committed(_ f: Fixture) throws -> ([HomeLeaveStatus], [UUID: HomeAccessRecord]) {
        let context = f.persistence.container.newBackgroundContext()
        return try context.performAndWait {
            defer { context.reset() }
            let repository = PersonalCartRepository(persistence: f.persistence, context: context, session: f.backend.session)
            return (try repository.homeLeaves(), try repository.values(HomeAccessRecord.self, kind: "homeAccess"))
        }
    }

    func testDurableSubmissionPrecedesHeldPurgeAndRetiredScreenStillCompletesWithoutLosingPrivateHistory() async throws {
        let f = try fixture(), authority = UICommandAuthority(), held = HeldCallback()
        let started = expectation(description: "Submitted native purge is held")
        let scope = f.identity.scope
        let cartBefore = try f.cart.transact(save: false) { try $0.values(PersonalCartCommandResult.self, kind: "cart") }
        let historyBefore = try f.cart.history(householdID: scope.householdID, listID: scope.listID)
        XCTAssertFalse(cartBefore.isEmpty)
        XCTAssertEqual(historyBefore.count, 1)
        let command = try await f.transport.prepare(identity: f.identity, authority: authority)
        XCTAssertTrue(try f.cart.retainedHomeLeaves().isEmpty, "Preparing confirmation is not authorization")
        f.backend.purgeAction = { command in
            let (statuses, access) = try Self.committed(f)
            XCTAssertEqual(statuses.first?.command, command)
            XCTAssertEqual(statuses.first?.submitted, true)
            XCTAssertEqual(statuses.first?.completed, false)
            XCTAssertEqual(access[command.quarantineID], command.quarantine)
            await held.hold { started.fulfill() }
            try Self.deleteGraph(f)
            return HomeLeaveZone(share: command.origin.share)
        }
        let operation = Task { try await f.transport.execute(command, authority: authority) }
        await fulfillment(of: [started], timeout: 3)
        authority.retire()
        await held.release() // Always release before any throwing result assertion.
        let result = try await operation.value
        XCTAssertTrue(result.completed)
        XCTAssertEqual(f.backend.purgeCount, 1)
        XCTAssertEqual(try f.cart.transact(save: false) { try $0.values(PersonalCartCommandResult.self, kind: "cart") }, cartBefore)
        XCTAssertEqual(try f.cart.history(householdID: scope.householdID, listID: scope.listID), historyBefore)
        XCTAssertEqual(try Self.committed(f).1[command.quarantineID], command.quarantine)
        XCTAssertTrue(try HomeDiscoveryService(persistence: f.persistence).discover().homes.isEmpty)
    }

    func testNativeFailureNeverResubmitsAndReconciliationRequiresZoneAndLocalAbsence() async throws {
        let f = try fixture()
        let command = try await f.transport.prepare(identity: f.identity)
        f.backend.purgeAction = { _ in throw Failure.native }
        do { _ = try await f.transport.execute(command); XCTFail("Native failure must remain visible") }
        catch { XCTAssertTrue(error is Failure) }
        let repeated = try await f.transport.execute(command)
        XCTAssertFalse(repeated.completed)
        XCTAssertEqual(f.backend.purgeCount, 1)
        f.backend.zoneAction = { _ in throw Failure.zoneUnavailable }
        do { _ = try await f.transport.reconcile(command); XCTFail("Failed observation cannot complete leave") }
        catch { XCTAssertTrue(error is Failure) }
        XCTAssertFalse(try XCTUnwrap(Self.committed(f).0.first).completed)
        f.backend.zoneAction = { _ in false }
        do { _ = try await f.transport.reconcile(command); XCTFail("Server absence alone is insufficient") }
        catch { XCTAssertTrue(error is ManagedHomeLeaveTransport.Failure) }
        try Self.deleteGraph(f)
        let reconciled = try await f.transport.reconcile(command)
        XCTAssertTrue(reconciled.completed)
        XCTAssertEqual(f.backend.purgeCount, 1)
        XCTAssertEqual(try Self.committed(f).1[command.quarantineID], command.quarantine)
    }

    func testReadOnlyAcceptedContributorCanLeave() async throws {
        let f = try fixture()
        f.backend.membershipValue = Backend.membership(f.identity, permission: .readOnly)
        let command = try await f.transport.prepare(identity: f.identity)
        f.backend.purgeAction = { command in
            try Self.deleteGraph(f)
            return HomeLeaveZone(share: command.origin.share)
        }
        let result = try await f.transport.execute(command)
        XCTAssertTrue(result.submitted)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(f.backend.purgeCount, 1)
        XCTAssertEqual(try Self.committed(f).1[command.quarantineID], command.quarantine)
    }

    func testUncertainSubmissionSurvivesSQLiteReopenAndNeverPurgesAgain() async throws {
        let original = try fixture()
        let command = try await original.transport.prepare(identity: original.identity)
        original.backend.purgeAction = { _ in throw Failure.native }
        do { _ = try await original.transport.execute(command); XCTFail("Native failure must remain visible") }
        catch { XCTAssertTrue(error is Failure) }
        let originalStore = try XCTUnwrap(original.persistence.primaryStore)
        let url = try XCTUnwrap(originalStore.url)
        let history = try original.cart.history(householdID: command.origin.scope.householdID,
            listID: command.origin.scope.listID)
        XCTAssertEqual(original.backend.purgeCount, 1)
        try close(original.persistence)

        // Rebuild every runtime component against the same on-disk records.
        // No actor state, backend counter or live service authorizes this retry.
        let persistence = try PersistenceController(storeURL: url)
        addTeardownBlock { try self.close(persistence) }
        XCTAssertFalse(try XCTUnwrap(persistence.primaryStore) === originalStore)
        let provider = Provider(original.backend.session)
        let cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
        let backend = Backend(persistence: persistence, provider: provider,
            session: original.backend.session, identity: command.origin)
        let reopened = Fixture(persistence: persistence, cart: cart, provider: provider,
            identity: command.origin, backend: backend)
        backend.purgeAction = { _ in
            XCTFail("A reopened submitted command must never call purge again")
            throw Failure.native
        }
        let retained = try XCTUnwrap(Self.committed(reopened).0.first)
        XCTAssertEqual(retained.command, command)
        XCTAssertTrue(retained.submitted)
        XCTAssertFalse(retained.completed)
        XCTAssertEqual(try Self.committed(reopened).1[command.quarantineID], command.quarantine)

        let retry = try await reopened.transport.execute(command)
        XCTAssertTrue(retry.requiresResolution)
        let stillPresent = try await reopened.transport.reconcile(command)
        XCTAssertTrue(stillPresent.requiresResolution)
        XCTAssertEqual(backend.purgeCount, 0)
        try Self.deleteGraph(reopened)
        backend.zoneAction = { _ in false }
        let completed = try await reopened.transport.reconcile(command)
        XCTAssertTrue(completed.completed)
        XCTAssertEqual(backend.purgeCount, 0)
        XCTAssertEqual(original.backend.purgeCount, 1)
        XCTAssertEqual(try cart.history(householdID: command.origin.scope.householdID,
            listID: command.origin.scope.listID), history)
        XCTAssertEqual(try Self.committed(reopened).1[command.quarantineID], command.quarantine)
    }

    func testWrongReturnedZoneNeverCompletesEvenWhenLocalGraphWasRemoved() async throws {
        let f = try fixture()
        let command = try await f.transport.prepare(identity: f.identity)
        f.backend.purgeAction = { _ in
            try Self.deleteGraph(f)
            return HomeLeaveZone(name: "different-zone", ownerName: "owner")
        }
        do { _ = try await f.transport.execute(command); XCTFail("Wrong zone callback must not complete") }
        catch { XCTAssertTrue(error is ManagedHomeLeaveTransport.Failure) }
        XCTAssertFalse(try XCTUnwrap(Self.committed(f).0.first).completed)
        let stillPending = try await f.transport.execute(command)
        XCTAssertFalse(stillPending.completed)
        XCTAssertEqual(f.backend.purgeCount, 1)
    }

    func testRemainingOriginalListPreventsCompletionAfterRootDeletion() async throws {
        let f = try fixture()
        let command = try await f.transport.prepare(identity: f.identity)
        f.backend.purgeAction = { command in
            try Self.deleteGraph(f, keepList: true)
            return HomeLeaveZone(share: command.origin.share)
        }
        do { _ = try await f.transport.execute(command); XCTFail("The original list is still present") }
        catch { XCTAssertTrue(error is ManagedHomeLeaveTransport.Failure) }
        XCTAssertFalse(try XCTUnwrap(Self.committed(f).0.first).completed)
        f.backend.zoneAction = { _ in false }
        do { _ = try await f.transport.reconcile(command); XCTFail("Both root and list must be absent") }
        catch { XCTAssertTrue(error is ManagedHomeLeaveTransport.Failure) }
        try Self.deleteGraph(f)
        let result = try await f.transport.reconcile(command)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(f.backend.purgeCount, 1)
    }

    func testAccountChangeDuringHeldCallbackCannotCompleteOriginalLeave() async throws {
        let f = try fixture(), held = HeldCallback()
        let started = expectation(description: "Native callback held before account changes")
        let command = try await f.transport.prepare(identity: f.identity)
        f.backend.purgeAction = { command in
            await held.hold { started.fulfill() }
            try Self.deleteGraph(f)
            return HomeLeaveZone(share: command.origin.share)
        }
        let other = try ShopperSession.authenticated(containerIdentifier: f.backend.session.containerIdentifier,
            environment: f.backend.session.environment, accountRecordName: "other-account")
        let operation = Task { try await f.transport.execute(command) }
        await fulfillment(of: [started], timeout: 3)
        f.provider.replace(with: other)
        await held.release()
        do { _ = try await operation.value; XCTFail("Late account callback must be rejected") }
        catch { XCTAssertEqual(error as? PersonalCartError, .accountChanged) }
        let retained = try XCTUnwrap(Self.committed(f).0.first)
        XCTAssertTrue(retained.submitted)
        XCTAssertFalse(retained.completed)
        XCTAssertEqual(f.backend.purgeCount, 1)
    }

    func testRetiringConfirmationDuringMembershipRefreshPreventsDurableSubmission() async throws {
        let f = try fixture(), held = HeldCallback(), authority = UICommandAuthority()
        let command = try await f.transport.prepare(identity: f.identity, authority: authority)
        let started = expectation(description: "Fresh participant lookup held")
        f.backend.membershipAction = { await held.hold { started.fulfill() } }
        let operation = Task { try await f.transport.execute(command, authority: authority) }
        await fulfillment(of: [started], timeout: 3)
        authority.retire()
        await held.release()
        do { _ = try await operation.value; XCTFail("Retired confirmation cannot authorize leave") }
        catch { XCTAssertEqual(error as? UICommandAuthority.Failure, .retired) }
        XCTAssertTrue(try Self.committed(f).0.isEmpty)
        XCTAssertEqual(f.backend.purgeCount, 0)
    }

    func testOwnDurableQuarantineCanRetirePresentationWithoutStrandingAuthorizedLeave() async throws {
        let f = try fixture(), authority = UICommandAuthority()
        let command = try await f.transport.prepare(identity: f.identity, authority: authority)
        f.backend.mappingAction = { repository in
            if try repository.homeLeaves().contains(where: { $0.id == command.id && $0.submitted }) {
                // Discovery may retire this screen as soon as its own durable
                // quarantine arrives. Authorization already belongs to the ledger.
                authority.retire()
            }
        }
        f.backend.purgeAction = { command in
            XCTAssertFalse(authority.isActive)
            try Self.deleteGraph(f)
            return HomeLeaveZone(share: command.origin.share)
        }
        let result = try await f.transport.execute(command, authority: authority)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(f.backend.purgeCount, 1)
        XCTAssertFalse(authority.isActive)
    }

    func testCoveringGrantImportedAfterSubmissionPreventsNativePurge() async throws {
        let f = try fixture()
        let command = try await f.transport.prepare(identity: f.identity)
        let grant = HomeAccessRecord(id: UUID(), scope: command.origin.scope, share: command.origin.share,
            action: .joined(observedBlockIDs: [command.quarantineID]))
        f.backend.mappingAction = { repository in
            if try repository.homeLeaves().contains(where: { $0.id == command.id && $0.submitted }) {
                try repository.insert(id: grant.id, kind: "homeAccess", command: grant, value: grant)
                // Simulate a remote import becoming durable during final graph
                // validation. The following production ledger check must see it.
                try repository.context.save()
            }
        }
        do { _ = try await f.transport.execute(command); XCTFail("Newer membership retires purge authorization") }
        catch { XCTAssertEqual(error as? PersonalCartError, .scopeChanged) }
        let (statuses, records) = try Self.committed(f)
        let retained = try XCTUnwrap(statuses.first)
        XCTAssertTrue(retained.submitted)
        XCTAssertFalse(retained.completed)
        XCTAssertEqual(records[command.quarantineID], command.quarantine)
        XCTAssertEqual(records[grant.id], grant)
        XCTAssertEqual(f.backend.purgeCount, 0)
    }

    func testFreshOwnerPendingPublicOrDifferentParticipantCannotExecuteConfirmation() async throws {
        for variant in 0..<4 {
            let f = try fixture()
            let command = try await f.transport.prepare(identity: f.identity)
            switch variant {
            case 0: f.backend.membershipValue = Backend.membership(f.identity, role: .owner)
            case 1: f.backend.membershipValue = Backend.membership(f.identity, acceptance: .pending)
            case 2: f.backend.membershipValue = Backend.membership(f.identity, privateShare: false)
            default: f.backend.membershipValue = Backend.membership(f.identity, participantID: "replacement-participant")
            }
            do { _ = try await f.transport.execute(command); XCTFail("Invalid membership variant \(variant) must not purge") }
            catch { XCTAssertTrue(error is ManagedHomeLeaveTransport.Failure) }
            XCTAssertEqual(f.backend.purgeCount, 0)
            XCTAssertTrue(try Self.committed(f).0.isEmpty)
        }
    }

    func testAnotherLogicalHomeKnownInSameZonePreventsPurge() async throws {
        let f = try fixture()
        let command = try await f.transport.prepare(identity: f.identity)
        let other = HomeAccessRecord(id: UUID(), scope: HomeEffectScope(session: f.backend.session,
            householdID: UUID(), listID: UUID()), share: f.identity.share, action: .blocked(.revoked))
        try f.cart.transact { try $0.insert(id: other.id, kind: "homeAccess", command: other, value: other) }
        do { _ = try await f.transport.execute(command); XCTFail("Zone-wide purge cannot include another known home") }
        catch { XCTAssertTrue(error is ManagedHomeLeaveTransport.Failure) }
        XCTAssertEqual(f.backend.purgeCount, 0)
        XCTAssertTrue(try Self.committed(f).0.isEmpty)
    }
}
