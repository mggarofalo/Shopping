import CoreData
import XCTest
@testable import Shopping

final class HomeRejoinTests: XCTestCase {
    private final class Provider: ShopperSessionProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var session: ShopperSession
        init(_ session: ShopperSession) { self.session = session }
        func currentSession() throws -> ShopperSession { lock.withLock { session } }
        func change(to session: ShopperSession) { lock.withLock { self.session = session } }
    }

    /// Replaces native CloudKit verification only. Graph validation and all saves
    /// still use the real local SQLite repository; this is not sharing proof.
    private struct LocalVerifier: HomeRejoinVerifying {
        var duringRefresh: @Sendable () async throws -> Void = {}
        var duringValidation: @Sendable () throws -> Void = {}
        func validate(_ identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws {
            guard !repository.persistence.configuration.isManaged else { throw PersonalCartError.unavailable }
            try duringValidation()
        }
        func refresh(_ identity: HomeNativeAccessIdentity) async throws { try await duringRefresh() }
    }

    private struct Fixture {
        let persistence: PersistenceController
        let cart: PersonalCartService
        let provider: Provider
        let identity: HomeNativeAccessIdentity
        let needID: UUID
        var scope: HomeEffectScope { identity.scope }
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
        let persistence = try PersistenceController(storeURL: directory.appendingPathComponent("Home.sqlite"))
        addTeardownBlock { try self.close(persistence) }
        let needs = NeedService(persistence: persistence)
        let home = try needs.createHousehold(name: "Invited home")
        let need = try needs.addOneTimeNeed(title: "Milk", quantity: 2,
            householdID: home.householdID, listID: home.listID)
        let graph = try XCTUnwrap(HomeDiscoveryService(persistence: persistence).discover().homes.first?.graph)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.rejoin",
            environment: "Development", accountRecordName: "participant")
        let provider = Provider(session)
        let cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
        try cart.cart(needID: need, householdID: home.householdID, listID: home.listID)
        let identity = HomeNativeAccessIdentity(
            scope: HomeEffectScope(session: session, householdID: home.householdID, listID: home.listID),
            storeIdentifier: graph.storeIdentifier, rootURI: graph.rootURI,
            share: HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner"))
        return Fixture(persistence: persistence, cart: cart, provider: provider, identity: identity, needID: need)
    }

    @discardableResult
    private func revoke(_ f: Fixture) throws -> UUID {
        let id = UUID()
        try f.cart.blockHomeEffects(householdID: f.scope.householdID, listID: f.scope.listID,
            share: f.identity.share, reason: .revoked, operationID: id)
        return id
    }

    private func access(_ f: Fixture) throws -> HomeEffectAccess {
        try f.cart.transact(save: false) {
            try $0.homeEffectAccess(householdID: f.scope.householdID, listID: f.scope.listID)
        }
    }

    private func grants(_ f: Fixture) throws -> [HomeAccessRecord] {
        try f.cart.transact(save: false) {
            try $0.values(HomeAccessRecord.self, kind: "homeAccess").values.filter {
                if case .joined = $0.action { return true }
                return false
            }
        }
    }

    func testNewLossDuringNativeRefreshRejectsCapturedOpenWithoutWritingGrant() async throws {
        let f = try fixture()
        try revoke(f)
        let cart = f.cart, scope = f.scope, share = f.identity.share
        let verifier = LocalVerifier(duringRefresh: {
            try cart.blockHomeEffects(householdID: scope.householdID, listID: scope.listID,
                share: share, reason: .revoked, operationID: UUID())
        })
        let command = try f.cart.captureHomeRejoin(entryID: UUID(), identity: f.identity, verifier: verifier)
        try await verifier.refresh(f.identity)
        XCTAssertThrowsError(try f.cart.commitHomeRejoin(command, verifier: verifier)) {
            XCTAssertEqual($0 as? PersonalCartError, .scopeChanged)
        }
        XCTAssertTrue(try grants(f).isEmpty)
        XCTAssertTrue(try access(f).requiresExplicitRejoin)
    }

    func testRepeatedOpenIsIdempotentAcrossReopenButLaterLossNeedsANewGrant() throws {
        let f = try fixture(), verifier = LocalVerifier(), entryID = UUID()
        try revoke(f)
        let first = try f.cart.captureHomeRejoin(entryID: entryID, identity: f.identity, verifier: verifier)
        try f.cart.commitHomeRejoin(first, verifier: verifier)
        try f.cart.commitHomeRejoin(first, verifier: verifier)
        XCTAssertEqual(try grants(f).map(\.id), [first.grant.id])
        XCTAssertFalse(try access(f).requiresExplicitRejoin)
        let url = try XCTUnwrap(f.persistence.primaryStore?.url)
        try close(f.persistence)
        let reopened = try PersistenceController(storeURL: url)
        addTeardownBlock { try self.close(reopened) }
        let cart = PersonalCartService(persistence: reopened, sessionProvider: f.provider)
        let repeated = try cart.captureHomeRejoin(entryID: entryID, identity: f.identity, verifier: verifier)
        XCTAssertEqual(repeated.grant.id, first.grant.id)
        try cart.commitHomeRejoin(repeated, verifier: verifier)
        try cart.blockHomeEffects(householdID: f.scope.householdID, listID: f.scope.listID,
            share: f.identity.share, reason: .revoked, operationID: UUID())
        let next = try cart.captureHomeRejoin(entryID: entryID, identity: f.identity, verifier: verifier)
        XCTAssertNotEqual(next.grant.id, first.grant.id)
        XCTAssertThrowsError(try cart.commitHomeRejoin(first, verifier: verifier))
        try cart.commitHomeRejoin(next, verifier: verifier)
        let joined = try cart.transact(save: false) {
            try $0.values(HomeAccessRecord.self, kind: "homeAccess").values.filter {
                if case .joined = $0.action { return true }; return false
            }
        }
        XCTAssertEqual(Set(joined.map(\.id)), [first.grant.id, next.grant.id])
    }

    func testRejoinDoesNotPromoteOldCartCheckoutOrRestoreEffects() throws {
        let f = try fixture(), verifier = LocalVerifier()
        let restriction = UUID()
        try f.cart.recordReadOnlyHome(householdID: f.scope.householdID, listID: f.scope.listID,
            share: f.identity.share, operationID: restriction)
        let entries = try f.cart.entries(householdID: f.scope.householdID, listID: f.scope.listID)
        let token = try f.cart.prepareCheckout(tokens: entries.map(\.token))
        let checkout = try f.cart.checkout(token)
        XCTAssertTrue(checkout.pendingPublication)
        let restore = try f.cart.restore(checkoutID: checkout.operationID)
        XCTAssertTrue(restore.pendingPublication)
        let before = try f.cart.transact(save: false) { repository in
            Dictionary(uniqueKeysWithValues: try repository.privateRecords()
                .filter { ["cart", "checkout", "restore"].contains($0.kind) }.map { ($0.id, $0.payload) })
        }
        try revoke(f)
        try f.cart.recordWritableHome(householdID: f.scope.householdID, listID: f.scope.listID,
            share: f.identity.share, observedRestrictionIDs: [restriction], operationID: UUID())
        let command = try f.cart.captureHomeRejoin(entryID: UUID(), identity: f.identity, verifier: verifier)
        try f.cart.commitHomeRejoin(command, verifier: verifier)
        XCTAssertFalse(try access(f).requiresExplicitRejoin)
        try f.cart.resumePending()
        try f.cart.transact(save: false) { repository in
            for (kind, id) in [(HomeEffectKind.checkout, checkout.operationID), (.restore, restore.operationID),
                               (.cartGeneration, try XCTUnwrap(entries.first).token.generation)] {
                XCTAssertFalse(try repository.homeEffectMayPublish(kind: kind, subjectID: id,
                    householdID: f.scope.householdID, listID: f.scope.listID))
            }
            let after = Dictionary(uniqueKeysWithValues: try repository.privateRecords()
                .filter { ["cart", "checkout", "restore"].contains($0.kind) }.map { ($0.id, $0.payload) })
            XCTAssertEqual(after, before)
            XCTAssertTrue(try repository.values(UUID.self, kind: "published").isEmpty)
            XCTAssertTrue(try repository.values(UUID.self, kind: "restorePublished").isEmpty)
        }
        XCTAssertThrowsError(try f.cart.checkout(token)) {
            XCTAssertEqual($0 as? PersonalCartError, .scopeChanged)
        }
    }

    func testReadOnlyRejoinRestoresMembershipWithoutRestoringPublication() throws {
        let f = try fixture(), verifier = LocalVerifier()
        try revoke(f)
        try f.cart.recordReadOnlyHome(householdID: f.scope.householdID, listID: f.scope.listID,
            share: f.identity.share, operationID: UUID())
        let command = try f.cart.captureHomeRejoin(entryID: UUID(), identity: f.identity, verifier: verifier)
        try f.cart.commitHomeRejoin(command, verifier: verifier)
        let result = try access(f)
        XCTAssertFalse(result.requiresExplicitRejoin)
        XCTAssertFalse(result.permitsPublication(result.capturedAuthority))
        let entry = try XCTUnwrap(f.cart.entries(householdID: f.scope.householdID, listID: f.scope.listID).first)
        try f.cart.setQuantity(7, token: entry.token)
        XCTAssertEqual(try f.cart.entries(householdID: f.scope.householdID, listID: f.scope.listID).first?.quantity, 7)
        XCTAssertThrowsError(try f.cart.cart(needID: f.needID, householdID: f.scope.householdID, listID: f.scope.listID))
    }

    func testImportedGraphDriftAndChangedAccountRejectPreviouslyCapturedOpen() throws {
        for drift in ["root", "rootURI", "list", "duplicateList", "account", "store"] {
            let f = try fixture(), verifier = LocalVerifier()
            var command = try f.cart.captureHomeRejoin(entryID: UUID(), identity: f.identity, verifier: verifier)
            if drift == "rootURI" {
                let changed = HomeNativeAccessIdentity(scope: f.scope, storeIdentifier: f.identity.storeIdentifier,
                    rootURI: "x-coredata://another-store/Household/p1", share: f.identity.share)
                command = HomeRejoinCommand(entryID: command.entryID, identity: changed,
                    observedBlockIDs: command.observedBlockIDs)
            } else if drift == "account" {
                f.provider.change(to: try ShopperSession.authenticated(containerIdentifier: f.scope.containerIdentifier,
                    environment: f.scope.environment, accountRecordName: "other-participant"))
            } else if drift == "store" {
                try close(f.persistence)
            } else {
                // Represents a changed imported graph, not an authorized user edit.
                try f.persistence.writer.performAndWait {
                    let context = f.persistence.writer
                    context.reset()
                    let home = try XCTUnwrap(context.fetch(Household.fetchRequest()).first)
                    if drift == "root" { home.id = UUID() }
                    if drift == "list" { home.groceryList?.id = UUID() }
                    if drift == "duplicateList" {
                        let duplicate = try XCTUnwrap(NSEntityDescription.insertNewObject(
                            forEntityName: "GroceryList", into: context) as? GroceryList)
                        duplicate.id = f.scope.listID
                        context.assign(duplicate, to: try XCTUnwrap(f.persistence.primaryStore))
                    }
                    try context.save()
                }
            }
            XCTAssertThrowsError(try f.cart.commitHomeRejoin(command, verifier: verifier), drift)
        }
    }

    func testRetiredPresentationAndPendingLeaveRejectOpenWithoutGrant() throws {
        let f = try fixture(), verifier = LocalVerifier(), authority = UICommandAuthority()
        let scoped = f.cart.scoped(to: authority)
        let command = try scoped.captureHomeRejoin(entryID: UUID(), identity: f.identity, verifier: verifier)
        authority.retire()
        XCTAssertThrowsError(try scoped.commitHomeRejoin(command, verifier: verifier)) {
            XCTAssertEqual($0 as? UICommandAuthority.Failure, .retired)
        }
        let choice = UICommandAuthority()
        let retiringVerifier = LocalVerifier(duringValidation: { choice.retire() })
        XCTAssertThrowsError(try f.cart.commitHomeRejoin(command, verifier: retiringVerifier, choiceAuthority: choice)) {
            XCTAssertEqual($0 as? UICommandAuthority.Failure, .retired)
        }
        XCTAssertTrue(try grants(f).isEmpty, "Retirement after the initial transaction check must roll back the grant")
        let leave = HomeLeaveCommand(id: UUID(), origin: f.identity,
            storeURL: try XCTUnwrap(f.persistence.primaryStore?.url), participantID: "participant",
            homeName: "Invited home", evidence: try f.cart.captureHomeLeaveEvidence(scope: f.scope), confirmedAt: Date())
        try f.cart.retainHomeLeave(leave)
        XCTAssertThrowsError(try f.cart.commitHomeRejoin(command, verifier: verifier)) {
            guard case HomeLeaveError.pendingLeave = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try f.cart.captureHomeRejoin(entryID: UUID(), identity: f.identity, verifier: verifier)) {
            guard case HomeLeaveError.pendingLeave = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertTrue(try grants(f).isEmpty)
    }
}
