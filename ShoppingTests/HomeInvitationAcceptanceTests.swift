import CoreData
import XCTest
@testable import Shopping

final class HomeInvitationAcceptanceTests: XCTestCase {
    private enum Failure: Error { case observationUnavailable, afterCheckoutIntent }

    private struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func accept() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private final class PermissionPolicy: PersistencePermissionPolicy, @unchecked Sendable {
        private let lock = NSLock()
        private var denied = false
        func denyWrites() { lock.withLock { denied = true } }
        func validateChanges(in context: NSManagedObjectContext, controller: PersistenceController) throws {
            if lock.withLock({ denied }), context.hasChanges { throw PersistencePermissionError.updateDenied }
        }
    }

    /// Only the native observation/retained-share lookup is simulated. Observation
    /// records use the production reducer and real SQLite commit/rollback path.
    private struct Preflight: HomeInvitationAccessPreflighting {
        let cart: PersonalCartService
        let identity: HomeNativeAccessIdentity
        let observation: ManagedHomeAccessObserver.Observation
        var observationFails = false
        var knownShare = true
        var duringObservation: @Sendable () async throws -> Void = {}

        func captureAcceptance(share: HomeEffectShare, session: ShopperSession) async throws -> HomeInvitationAcceptance.Capture? {
            try cart.transact(save: false) { repository in
                guard repository.session == session, identity.share == share else { throw PersonalCartError.scopeChanged }
                guard knownShare else { return nil }
                let access = try repository.homeEffectAccess(householdID: identity.scope.householdID,
                    listID: identity.scope.listID)
                return HomeInvitationAcceptance.Capture(scope: identity.scope, share: share,
                    storeIdentifier: identity.storeIdentifier, nativeRequest: nil, restrictionIDs: access.restrictionIDs)
            }
        }

        func observeAcceptance(_ capture: HomeInvitationAcceptance.Capture) async throws -> ManagedHomeAccessObserver.Observation {
            if observationFails { throw Failure.observationUnavailable }
            try await duringObservation()
            return observation
        }

        func validateJoin(share: HomeEffectShare, session: ShopperSession) async throws {
            try cart.transact(save: false) { repository in
                guard repository.session == session else { throw PersonalCartError.accountChanged }
                try HomeJoinGate.requireAllowed(repository: repository, share: share)
            }
        }

        func persistAcceptance(_ observation: ManagedHomeAccessObserver.Observation,
            capture: HomeInvitationAcceptance.Capture) async throws {
            try cart.transact { repository in
                let access = try repository.homeEffectAccess(householdID: capture.scope.householdID, listID: capture.scope.listID)
                if let record = try ManagedHomeAccessObserver.record(observation, scope: capture.scope,
                    share: capture.share, access: access, capturedRestrictionIDs: capture.restrictionIDs) {
                    try repository.insert(id: record.id, kind: "homeAccess", command: record, value: record)
                }
            }
        }
    }

    private struct LocalRejoinVerifier: HomeRejoinVerifying {
        func validate(_ identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws {
            guard !repository.persistence.configuration.isManaged else { throw PersonalCartError.unavailable }
        }
        func refresh(_ identity: HomeNativeAccessIdentity) async throws {}
    }

    private struct Fixture {
        let persistence: PersistenceController
        let cart: PersonalCartService
        let session: ShopperSession
        let identity: HomeNativeAccessIdentity
        let policy: PermissionPolicy
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
        let policy = PermissionPolicy()
        let persistence = try PersistenceController(configuration: .local(storeURL: directory.appendingPathComponent("Home.sqlite")),
            permissionPolicy: policy)
        addTeardownBlock { try self.close(persistence) }
        let service = NeedService(persistence: persistence)
        let home = try service.createHousehold(name: "Known home")
        let need = try service.addOneTimeNeed(title: "Milk", quantity: 2, householdID: home.householdID, listID: home.listID)
        let graph = try XCTUnwrap(HomeDiscoveryService(persistence: persistence).discover().homes.first?.graph)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.acceptance",
            environment: "Development", accountRecordName: "participant")
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session))
        try cart.cart(needID: need, householdID: home.householdID, listID: home.listID)
        let identity = HomeNativeAccessIdentity(
            scope: HomeEffectScope(session: session, householdID: home.householdID, listID: home.listID),
            storeIdentifier: graph.storeIdentifier, rootURI: graph.rootURI,
            share: HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner"))
        return Fixture(persistence: persistence, cart: cart, session: session, identity: identity, policy: policy)
    }

    private static func committedAccess(cart: PersonalCartService) throws -> [HomeAccessRecord] {
        let context = cart.persistence.container.newBackgroundContext()
        return try context.performAndWait {
            defer { context.reset() }
            let repository = PersonalCartRepository(persistence: cart.persistence, context: context,
                session: try cart.sessionProvider.currentSession())
            return Array(try repository.values(HomeAccessRecord.self, kind: "homeAccess").values)
        }
    }

    func testObservedLossIsCommittedBeforeNativeAcceptanceAndSurvivesReopen() async throws {
        let f = try fixture(), calls = Calls()
        let preflight = Preflight(cart: f.cart, identity: f.identity, observation: .init(access: .lost, changeTag: "lost-version"))
        let cart = f.cart, identity = f.identity
        try await HomeInvitationAcceptance.perform(preflight: preflight, share: identity.share, session: f.session) {
            let records = try Self.committedAccess(cart: cart)
            XCTAssertEqual(records.count, 1)
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.scope, identity.scope)
            XCTAssertEqual(record.share, identity.share)
            guard case .blocked(.revoked) = record.action else { return XCTFail("Loss must be durable before acceptance") }
            calls.accept()
        }
        XCTAssertEqual(calls.value, 1)
        let before = try Self.committedAccess(cart: f.cart)
        let url = try XCTUnwrap(f.persistence.primaryStore?.url)
        try close(f.persistence)
        let reopened = try PersistenceController(storeURL: url)
        addTeardownBlock { try self.close(reopened) }
        let restored = PersonalCartService(persistence: reopened, sessionProvider: Provider(session: f.session))
        XCTAssertEqual(try Self.committedAccess(cart: restored), before)
    }

    func testObservedLossKeepsOldCheckoutQuarantinedAfterAcceptanceWritableRefreshAndExplicitOpen() async throws {
        let f = try fixture(), scope = f.identity.scope, calls = Calls()
        let token = try f.cart.prepareCheckout(tokens: f.cart.entries(householdID: scope.householdID, listID: scope.listID).map(\.token))
        let checkoutID = UUID()
        f.cart.failurePoint = { if $0 == "afterIntent" { throw Failure.afterCheckoutIntent } }
        XCTAssertThrowsError(try f.cart.checkout(token, operationID: checkoutID))
        f.cart.failurePoint = nil
        let original = try f.cart.transact(save: false) { try $0.values(PersonalCheckoutIntent.self, kind: "checkout")[checkoutID] }
        XCTAssertNotNil(original)
        let loss = Preflight(cart: f.cart, identity: f.identity, observation: .init(access: .lost, changeTag: nil))
        try await HomeInvitationAcceptance.perform(preflight: loss, share: f.identity.share, session: f.session) { calls.accept() }
        XCTAssertEqual(calls.value, 1)
        let writable = Preflight(cart: f.cart, identity: f.identity, observation: .init(access: .writable, changeTag: "accepted-version"))
        let capture = try await writable.captureAcceptance(share: f.identity.share, session: f.session)
        try await writable.persistAcceptance(writable.observation, capture: XCTUnwrap(capture))
        let verifier = LocalRejoinVerifier()
        let command = try f.cart.captureHomeRejoin(entryID: UUID(), identity: f.identity, verifier: verifier)
        try await verifier.refresh(f.identity)
        try f.cart.commitHomeRejoin(command, verifier: verifier)
        try f.cart.resumePending()
        try f.cart.transact(save: false) { repository in
            let access = try repository.homeEffectAccess(householdID: scope.householdID, listID: scope.listID)
            XCTAssertFalse(access.requiresExplicitRejoin)
            XCTAssertTrue(access.permitsPublication(access.capturedAuthority), "New commands have current membership")
            XCTAssertFalse(try repository.homeEffectMayPublish(kind: .checkout, subjectID: checkoutID,
                householdID: scope.householdID, listID: scope.listID))
            XCTAssertEqual(try repository.values(PersonalCheckoutIntent.self, kind: "checkout")[checkoutID], original)
            XCTAssertTrue(try repository.values(UUID.self, kind: "published").isEmpty)
            XCTAssertTrue(try PersonalCartRepository.sharedValues(HouseholdPurchaseEvent.self, kind: "purchase",
                householdID: scope.householdID, in: repository.context).isEmpty)
        }
    }

    func testFreshWritableObservationDoesNotInventLossFromPendingInvitationMetadata() async throws {
        let f = try fixture(), calls = Calls(), share = f.identity.share
        var entry = HomeInvitationInbox.Entry(id: UUID(), identity: HomeInvitationIdentity(
            containerIdentifier: f.session.containerIdentifier, environment: f.session.environment,
            share: HomeShareIdentity(recordName: share.recordName, zoneName: share.zoneName, zoneOwnerName: share.zoneOwnerName)),
            metadataArchive: Data(), session: f.session)
        entry.participantPending = true
        entry.requiresNativeAcceptance = true
        XCTAssertTrue(entry.participantPending)
        let preflight = Preflight(cart: f.cart, identity: f.identity, observation: .init(access: .writable, changeTag: "still-accepted"))
        let requested = entry.identity.share
        try await HomeInvitationAcceptance.perform(preflight: preflight,
            share: HomeEffectShare(recordName: requested.recordName, zoneName: requested.zoneName, zoneOwnerName: requested.zoneOwnerName),
            session: XCTUnwrap(entry.session)) { calls.accept() }
        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(try Self.committedAccess(cart: f.cart).isEmpty)
    }

    func testObservationFailureLeavesNativeAcceptanceUnsubmitted() async throws {
        let f = try fixture(), calls = Calls()
        let preflight = Preflight(cart: f.cart, identity: f.identity, observation: .init(access: .lost, changeTag: nil),
            observationFails: true)
        do {
            try await HomeInvitationAcceptance.perform(preflight: preflight, share: f.identity.share, session: f.session) { calls.accept() }
            XCTFail("Unavailable native observation must stop acceptance")
        } catch Failure.observationUnavailable {}
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(try Self.committedAccess(cart: f.cart).isEmpty)
    }

    func testFailedPersistenceRollsBackLossAndLeavesNativeAcceptanceUnsubmitted() async throws {
        let f = try fixture(), calls = Calls()
        let preflight = Preflight(cart: f.cart, identity: f.identity, observation: .init(access: .lost, changeTag: nil))
        f.policy.denyWrites()
        do {
            try await HomeInvitationAcceptance.perform(preflight: preflight, share: f.identity.share, session: f.session) { calls.accept() }
            XCTFail("Failed durable observation must stop acceptance")
        } catch {
            XCTAssertEqual(error as? PersistencePermissionError, .updateDenied)
        }
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(try Self.committedAccess(cart: f.cart).isEmpty)
        XCTAssertFalse(f.persistence.writer.performAndWait { f.persistence.writer.hasChanges })
    }

    func testPendingLeaveArrivingDuringObservationStopsAcceptanceAtFinalJoinGate() async throws {
        let f = try fixture(), calls = Calls(), cart = f.cart
        let leave = HomeLeaveCommand(id: UUID(), origin: f.identity,
            storeURL: try XCTUnwrap(f.persistence.primaryStore?.url), participantID: "participant", homeName: "Known home",
            evidence: try cart.captureHomeLeaveEvidence(scope: f.identity.scope), confirmedAt: Date())
        let preflight = Preflight(cart: cart, identity: f.identity,
            observation: .init(access: .writable, changeTag: "accepted-before-leave-import"), duringObservation: {
                // Hold the fake native response until the competing private import
                // commits. No clock, polling, or unbounded continuation is involved.
                try cart.retainHomeLeave(leave)
            })
        do {
            try await HomeInvitationAcceptance.perform(preflight: preflight, share: f.identity.share, session: f.session) { calls.accept() }
            XCTFail("A pending leave imported after capture must stop native acceptance")
        } catch {
            guard case HomeLeaveError.pendingLeave = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(try XCTUnwrap(cart.retainedHomeLeaves().first).requiresResolution)
        XCTAssertTrue(try Self.committedAccess(cart: cart).contains(leave.quarantine))
    }

    func testFirstJoinWithoutRetainedCaptureAcceptsOnceWithoutObservingOrInventingAccessRecords() async throws {
        let f = try fixture(), calls = Calls()
        let preflight = Preflight(cart: f.cart, identity: f.identity,
            observation: .init(access: .lost, changeTag: nil), observationFails: true, knownShare: false)
        try await HomeInvitationAcceptance.perform(preflight: preflight,
            share: f.identity.share, session: f.session) { calls.accept() }
        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(try Self.committedAccess(cart: f.cart).isEmpty)
    }

    func testPendingLeaveBlocksAcceptanceEvenWithoutRetainedCapture() async throws {
        let f = try fixture(), calls = Calls()
        let leave = HomeLeaveCommand(id: UUID(), origin: f.identity,
            storeURL: try XCTUnwrap(f.persistence.primaryStore?.url), participantID: "participant", homeName: "Known home",
            evidence: try f.cart.captureHomeLeaveEvidence(scope: f.identity.scope), confirmedAt: Date())
        try f.cart.retainHomeLeave(leave)
        let before = try Self.committedAccess(cart: f.cart)
        let preflight = Preflight(cart: f.cart, identity: f.identity,
            observation: .init(access: .writable, changeTag: "accepted"), observationFails: true, knownShare: false)
        do {
            try await HomeInvitationAcceptance.perform(preflight: preflight,
                share: f.identity.share, session: f.session) { calls.accept() }
            XCTFail("The final join gate must run even when capture returns nil")
        } catch {
            guard case HomeLeaveError.pendingLeave = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(try Self.committedAccess(cart: f.cart), before)
        XCTAssertTrue(try XCTUnwrap(f.cart.retainedHomeLeaves().first).requiresResolution)
    }
}
