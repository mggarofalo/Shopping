import CoreData
import XCTest
@testable import Shopping

final class HomeLeaveLedgerTests: XCTestCase {
    private enum Interruption: Error { case afterIntent }
    private struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }
    private struct Fixture {
        let persistence: PersistenceController
        let cart: PersonalCartService
        let session: ShopperSession
        let command: HomeLeaveCommand
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
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let persistence = try PersistenceController(storeURL: directory.appendingPathComponent("Private.sqlite"))
        addTeardownBlock { try self.close(persistence) }
        let needs = NeedService(persistence: persistence)
        let home = try needs.createHousehold(name: "Original home")
        let need = try needs.addOneTimeNeed(title: "Milk", quantity: 2, householdID: home.householdID, listID: home.listID)
        let graph = try XCTUnwrap(HomeDiscoveryService(persistence: persistence).discover().homes.first?.graph)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.leave",
            environment: "Development", accountRecordName: "contributor")
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session))
        try cart.cart(needID: need, householdID: home.householdID, listID: home.listID)
        let scope = HomeEffectScope(session: session, householdID: home.householdID, listID: home.listID)
        let identity = HomeNativeAccessIdentity(scope: scope, storeIdentifier: graph.storeIdentifier,
            rootURI: graph.rootURI, share: HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner"))
        let command = HomeLeaveCommand(id: UUID(), origin: identity, storeURL: directory.appendingPathComponent("Shared.sqlite"),
            participantID: "contributor", homeName: "Original home", evidence: try cart.captureHomeLeaveEvidence(scope: scope),
            confirmedAt: Date())
        return Fixture(persistence: persistence, cart: cart, session: session, command: command)
    }

    private func access(_ f: Fixture) throws -> HomeEffectAccess {
        try f.cart.transact(save: false) {
            try $0.homeEffectAccess(householdID: f.command.origin.scope.householdID, listID: f.command.origin.scope.listID)
        }
    }

    func testConfirmedLeaveAndQuarantineSurviveReopenWithPrivateCartAndHomeRetained() throws {
        let f = try fixture(), scope = f.command.origin.scope
        let before = try f.cart.entries(householdID: scope.householdID, listID: scope.listID)
        XCTAssertEqual(f.command.evidence.cartGenerations, Set(before.map { $0.token.generation }))
        try f.cart.retainHomeLeave(f.command)
        try f.cart.retainHomeLeave(f.command)
        XCTAssertTrue(try access(f).requiresExplicitRejoin)
        XCTAssertEqual(try f.cart.retainedHomeLeaves().count, 1)
        XCTAssertEqual(try f.cart.entries(householdID: scope.householdID, listID: scope.listID), before)
        let url = try XCTUnwrap(f.persistence.primaryStore?.url)
        try close(f.persistence)
        let reopened = try PersistenceController(storeURL: url)
        addTeardownBlock { try self.close(reopened) }
        let cart = PersonalCartService(persistence: reopened, sessionProvider: Provider(session: f.session))
        XCTAssertEqual(try cart.retainedHomeLeaves().first?.command, f.command)
        XCTAssertEqual(try cart.homeEffectBoundary(householdID: scope.householdID, listID: scope.listID), [f.command.quarantineID])
        XCTAssertEqual(try cart.entries(householdID: scope.householdID, listID: scope.listID), before)
        XCTAssertEqual(try HomeDiscoveryService(persistence: reopened).discover().homes.first?.name, "Original home")
    }

    func testSubmissionIsAtMostOnceAndCompletionNeverGrantsMembership() throws {
        let f = try fixture(), command = f.command
        try f.cart.retainHomeLeave(command)
        let foreign = HomeNativeAccessIdentity(scope: command.origin.scope, storeIdentifier: "other-device",
            rootURI: command.origin.rootURI, share: command.origin.share)
        XCTAssertFalse(try f.cart.beginHomeLeaveSubmission(command, identity: foreign, storeURL: command.storeURL))
        XCTAssertFalse(try f.cart.beginHomeLeaveSubmission(command, identity: command.origin,
            storeURL: command.storeURL.deletingLastPathComponent().appendingPathComponent("Other.sqlite")))
        XCTAssertTrue(try f.cart.beginHomeLeaveSubmission(command, identity: command.origin, storeURL: command.storeURL))
        XCTAssertFalse(try f.cart.beginHomeLeaveSubmission(command, identity: command.origin, storeURL: command.storeURL))
        XCTAssertTrue(try XCTUnwrap(f.cart.retainedHomeLeaves().first).requiresResolution)
        try f.cart.completeHomeLeave(command)
        try f.cart.completeHomeLeave(command)
        XCTAssertFalse(try XCTUnwrap(f.cart.retainedHomeLeaves().first).requiresResolution)
        XCTAssertFalse(try f.cart.beginHomeLeaveSubmission(command, identity: command.origin, storeURL: command.storeURL))
        XCTAssertTrue(try access(f).requiresExplicitRejoin)
    }

    func testCheckpointBeforeCommandOrBlockImportsFailsClosedAndCannotAuthorizePurge() throws {
        let f = try fixture(), command = f.command
        let checkpoint = HomeLeaveCheckpoint(command: command, stage: .completed)
        try f.cart.transact { try $0.insert(id: checkpoint.id, kind: "homeLeaveCheckpoint", command: checkpoint, value: checkpoint) }
        XCTAssertEqual(try f.cart.retainedHomeLeaves().first?.command, command)
        XCTAssertFalse(try access(f).hasCompleteBoundary)
        XCTAssertTrue(try access(f).requiresExplicitRejoin)
        XCTAssertFalse(try f.cart.beginHomeLeaveSubmission(command, identity: command.origin, storeURL: command.storeURL))
        try f.cart.retainHomeLeave(command)
        XCTAssertTrue(try access(f).hasCompleteBoundary)
        XCTAssertTrue(try access(f).requiresExplicitRejoin, "A completed leave is not a rejoin grant")
    }

    func testCoveringRejoinPermanentlyRetiresUnsubmittedDestructiveAuthorization() throws {
        let f = try fixture(), command = f.command, scope = f.command.origin.scope
        try f.cart.retainHomeLeave(command)
        try f.cart.grantHomeEffects(householdID: scope.householdID, listID: scope.listID, share: command.origin.share,
            observedBlockIDs: [command.quarantineID], operationID: UUID())
        // Simulates reordering: a newer grant is visible before this device sees
        // the completion checkpoint. It must never execute the older purge.
        XCTAssertFalse(try f.cart.beginHomeLeaveSubmission(command, identity: command.origin, storeURL: command.storeURL))
        XCTAssertFalse(try access(f).requiresExplicitRejoin)
    }

    func testFailedSaveRetainsNeitherLeaveAuthorizationNorQuarantine() throws {
        let f = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let persistence = try PersistenceController(configuration: .local(storeURL: directory.appendingPathComponent("Denied.sqlite")),
            permissionPolicy: DenyPersistencePermissionPolicy())
        addTeardownBlock { try self.close(persistence) }
        let cart = PersonalCartService(persistence: persistence, sessionProvider: Provider(session: f.session))
        XCTAssertThrowsError(try cart.retainHomeLeave(f.command)) {
            XCTAssertEqual($0 as? PersistencePermissionError, .updateDenied)
        }
        XCTAssertTrue(try cart.retainedHomeLeaves().isEmpty)
        XCTAssertTrue(try cart.homeEffectBoundary(householdID: f.command.origin.scope.householdID,
            listID: f.command.origin.scope.listID).isEmpty)
    }

    func testEvidenceCapturesUnpublishedCheckoutAndRestoreWithoutChangingTheirPayloads() throws {
        let f = try fixture(), scope = f.command.origin.scope
        let entries = try f.cart.entries(householdID: scope.householdID, listID: scope.listID)
        let token = try f.cart.prepareCheckout(tokens: entries.map(\.token))
        let checkoutID = UUID()
        f.cart.failurePoint = { if $0 == "afterIntent" { throw Interruption.afterIntent } }
        XCTAssertThrowsError(try f.cart.checkout(token, operationID: checkoutID))
        f.cart.failurePoint = nil
        XCTAssertEqual(try f.cart.captureHomeLeaveEvidence(scope: scope).checkoutIDs, [checkoutID])
        try f.cart.resumePending()
        XCTAssertTrue(try f.cart.captureHomeLeaveEvidence(scope: scope).checkoutIDs.isEmpty)
        try f.cart.recordReadOnlyHome(householdID: scope.householdID, listID: scope.listID,
            share: f.command.origin.share, operationID: UUID())
        let restoreID = UUID()
        let restored = try f.cart.restore(checkoutID: checkoutID, operationID: restoreID)
        XCTAssertTrue(restored.pendingPublication)
        let before = try f.cart.history(householdID: scope.householdID, listID: scope.listID)
        XCTAssertEqual(try f.cart.captureHomeLeaveEvidence(scope: scope).restoreIDs, [restoreID])
        XCTAssertEqual(try f.cart.history(householdID: scope.householdID, listID: scope.listID), before)
    }

    func testPartialPrivateImportDoesNotRequireAnotherDeviceToSyncBeforeLeaving() throws {
        let f = try fixture(), command = f.command, scope = f.command.origin.scope
        let restoreID = UUID()
        let restore = PersonalRestoreIntent(checkoutID: UUID(), restoredNeedIDs: [])
        try f.cart.transact { try $0.insert(id: restoreID, kind: "restore", command: restoreID, value: restore) }
        let evidence = try f.cart.captureHomeLeaveEvidence(scope: scope)
        XCTAssertEqual(evidence.unresolvedRestoreIDs, [restoreID])
        XCTAssertTrue(evidence.restoreIDs.isEmpty)
        // Another replica's older grant references a loss record not imported yet.
        let earlierGrant = HomeAccessRecord(id: UUID(), scope: scope, share: command.origin.share,
            action: .joined(observedBlockIDs: [UUID()]))
        try f.cart.transact { try $0.insert(id: earlierGrant.id, kind: "homeAccess", command: earlierGrant, value: earlierGrant) }
        try f.cart.retainHomeLeave(command)
        XCTAssertFalse(try access(f).hasCompleteBoundary)
        XCTAssertTrue(try f.cart.beginHomeLeaveSubmission(command, identity: command.origin, storeURL: command.storeURL))
        XCTAssertTrue(try access(f).requiresExplicitRejoin)
    }
}
