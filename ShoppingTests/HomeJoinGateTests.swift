import CoreData
import XCTest
@testable import Shopping

final class HomeJoinGateTests: XCTestCase {
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

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let persistence = try PersistenceController(storeURL: directory.appendingPathComponent("Private.sqlite"))
        addTeardownBlock {
            persistence.writer.performAndWait { persistence.writer.reset() }
            persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.join-gate",
            environment: "Development", accountRecordName: "contributor")
        let share = HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")
        let scope = HomeEffectScope(session: session, householdID: UUID(), listID: UUID())
        let command = HomeLeaveCommand(id: UUID(), origin: HomeNativeAccessIdentity(scope: scope,
            storeIdentifier: "shared-store", rootURI: "x-coredata://store/Household/p1", share: share),
            storeURL: directory.appendingPathComponent("Shared.sqlite"), participantID: "contributor", homeName: "Home",
            evidence: HomeLeaveEvidence(checkoutIDs: [], restoreIDs: [], unresolvedRestoreIDs: [], cartGenerations: []), confirmedAt: Date())
        return Fixture(persistence: persistence, cart: PersonalCartService(persistence: persistence, sessionProvider: Provider(session: session)),
            session: session, command: command)
    }

    private func check(_ f: Fixture, share: HomeEffectShare? = nil) throws {
        try f.cart.transact(save: false) { try HomeJoinGate.requireAllowed(repository: $0, share: share ?? f.command.origin.share) }
    }

    func testPendingLeaveBlocksEntireZoneButNotAnotherZone() throws {
        let f = try fixture()
        try check(f)
        try f.cart.retainHomeLeave(f.command)
        XCTAssertThrowsError(try check(f)) { XCTAssertTrue($0 is HomeLeaveError) }
        let sameZone = HomeEffectShare(recordName: "different-share-name", zoneName: "zone", zoneOwnerName: "owner")
        XCTAssertThrowsError(try check(f, share: sameZone))
        try check(f, share: HomeEffectShare(recordName: "share", zoneName: "other-zone", zoneOwnerName: "owner"))
        XCTAssertTrue(try f.cart.beginHomeLeaveSubmission(f.command, identity: f.command.origin, storeURL: f.command.storeURL))
        XCTAssertThrowsError(try check(f), "A submitted operation remains pending until its outcome is reconciled")
        try f.cart.completeHomeLeave(f.command)
        try check(f)
        let access = try f.cart.transact(save: false) {
            try $0.homeEffectAccess(householdID: f.command.origin.scope.householdID, listID: f.command.origin.scope.listID)
        }
        XCTAssertTrue(access.requiresExplicitRejoin, "Opening the gate is not a membership grant")
    }

    func testLeaveBlockArrivingBeforeItsCommandCannotBypassGate() throws {
        let f = try fixture(), block = f.command.quarantine
        try f.cart.transact { try $0.insert(id: block.id, kind: "homeAccess", command: block, value: block) }
        XCTAssertThrowsError(try check(f))
        try f.cart.retainHomeLeave(f.command)
        XCTAssertThrowsError(try check(f))
        try f.cart.completeHomeLeave(f.command)
        try check(f)
    }

    func testCompletionAndGrantBeforeMissingPrivateBlocksKeepGateClosed() throws {
        let f = try fixture()
        let checkpoint = HomeLeaveCheckpoint(command: f.command, stage: .completed)
        try f.cart.transact { try $0.insert(id: checkpoint.id, kind: "homeLeaveCheckpoint", command: checkpoint, value: checkpoint) }
        XCTAssertThrowsError(try check(f))
        try f.cart.retainHomeLeave(f.command)
        try check(f)
        let missing = HomeAccessRecord(id: UUID(), scope: f.command.origin.scope, share: f.command.origin.share, action: .blocked(.revoked))
        let grant = HomeAccessRecord(id: UUID(), scope: f.command.origin.scope, share: f.command.origin.share,
            action: .joined(observedBlockIDs: [missing.id, f.command.quarantineID]))
        try f.cart.transact { try $0.insert(id: grant.id, kind: "homeAccess", command: grant, value: grant) }
        XCTAssertThrowsError(try check(f))
        try f.cart.transact { try $0.insert(id: missing.id, kind: "homeAccess", command: missing, value: missing) }
        try check(f)
    }

    func testBackgroundGateReadUsesCapturedAccountPrivateRecords() async throws {
        let f = try fixture()
        try f.cart.retainHomeLeave(f.command)
        do {
            try await HomeJoinGate.validate(persistence: f.persistence, session: f.session, share: f.command.origin.share)
            XCTFail("The pending leave must block this account")
        } catch { XCTAssertTrue(error is HomeLeaveError) }
        let other = try ShopperSession.authenticated(containerIdentifier: f.session.containerIdentifier,
            environment: f.session.environment, accountRecordName: "other")
        // Native adapters separately validate that their captured account is still current.
        try await HomeJoinGate.validate(persistence: f.persistence, session: other, share: f.command.origin.share)
    }

    func testEachEffectImportedBeforeLeaveHistoryBlocksAcceptanceUntilCompletion() throws {
        for kind in ["cart", "checkout", "restore"] {
            let f = try fixture(), scope = f.command.origin.scope
            let authority = HomeEffectAuthority(observedBlockIDs: [f.command.quarantineID], grantID: nil)
            let id = UUID()
            try f.cart.transact { repository in
                switch kind {
                case "cart":
                    let token = PersonalCartEntryToken(accountBinding: f.session.accountBinding, householdID: scope.householdID,
                        listID: scope.listID, needID: UUID(), generation: UUID(), evidence: [], homeEffectAuthority: authority)
                    let snapshot = PersonalCartEntrySnapshot(title: "Retained milk", quantity: 1, notes: "", categoryID: nil,
                        categoryName: nil, categoryOrder: 0, urgency: "normal", anyStore: true, storeIDs: [],
                        purchaseRulesResolved: true, token: token, purchaseNotices: [], demandAvailable: false)
                    let result = PersonalCartCommandResult(edit: PersonalCartEdit(id: id, action: .remove,
                        snapshot: snapshot, ancestors: []), skipped: false)
                    try repository.insert(id: id, kind: kind, command: result, value: result)
                case "checkout":
                    let token = PersonalCheckoutToken(id: id, accountBinding: f.session.accountBinding,
                        householdID: scope.householdID, listID: scope.listID, storeID: nil, captures: [], homeEffectAuthority: authority)
                    let intent = PersonalCheckoutIntent(token: token, accepted: [], buyAnywayReceiptIDs: [], createdAt: Date())
                    try repository.insert(id: id, kind: kind, command: intent, value: intent)
                default:
                    let restore = PersonalRestoreIntent(checkoutID: UUID(), restoredNeedIDs: [],
                        homeEffectAuthority: authority, homeEffectScope: scope)
                    try repository.insert(id: id, kind: kind, command: restore, value: restore)
                }
            }
            XCTAssertThrowsError(try check(f), "\(kind) is evidence of missing membership history")
            // Without the block the effect's zone cannot safely be classified.
            XCTAssertThrowsError(try check(f, share: HomeEffectShare(recordName: "other", zoneName: "other", zoneOwnerName: "owner")))
            try f.cart.retainHomeLeave(f.command)
            XCTAssertThrowsError(try check(f), "The now-visible leave still has no native completion")
            try check(f, share: HomeEffectShare(recordName: "other", zoneName: "other", zoneOwnerName: "owner"))
            try f.cart.completeHomeLeave(f.command)
            try check(f)
        }
    }

    func testRestoreWithoutItsScopeOrCheckoutCannotHideMembershipDependencies() throws {
        let f = try fixture(), id = UUID()
        let restore = PersonalRestoreIntent(checkoutID: UUID(), restoredNeedIDs: [],
            homeEffectAuthority: HomeEffectAuthority(observedBlockIDs: [f.command.quarantineID], grantID: nil))
        try f.cart.transact { try $0.insert(id: id, kind: "restore", command: restore, value: restore) }
        try f.cart.retainHomeLeave(f.command)
        try f.cart.completeHomeLeave(f.command)
        XCTAssertThrowsError(try check(f), "An unclassified restore must wait for its checkout or declared scope")
    }

    func testZoneTurnSurvivesCallerCancellationAndNativeFailure() async throws {
        let f = try fixture()
        let zone = HomeParticipantZone(session: f.session, share: f.command.origin.share)
        let sameZone = HomeParticipantZone(session: f.session,
            share: HomeEffectShare(recordName: "another", zoneName: zone.zoneName, zoneOwnerName: zone.zoneOwnerName))
        XCTAssertEqual(zone, sameZone)
        let queued = expectation(description: "Join waits behind native leave")
        let coordinator = HomeParticipantOperationCoordinator { observed in
            XCTAssertEqual(observed, zone)
            queued.fulfill()
        }
        let started = expectation(description: "Native leave callback held")
        let native = HeldParticipantOperation()
        let leave = Task {
            try await coordinator.perform(in: zone) {
                await native.hold { started.fulfill() }
                await native.record("leave callback")
                throw HeldParticipantOperation.Failure.native
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let join = Task { try await coordinator.perform(in: sameZone) { await native.record("join") } }
        await fulfillment(of: [queued], timeout: 2)
        leave.cancel()
        let otherZone = HomeParticipantZone(session: f.session,
            share: HomeEffectShare(recordName: "share", zoneName: "independent", zoneOwnerName: "owner"))
        try await coordinator.perform(in: otherZone) { await native.record("other zone") }
        let before = await native.events
        XCTAssertEqual(before, ["other zone"], "Cancellation is not native completion")
        await native.release()
        do { _ = try await leave.value; XCTFail("The native failure must remain visible") }
        catch { XCTAssertTrue(error is HeldParticipantOperation.Failure) }
        try await join.value
        let after = await native.events
        XCTAssertEqual(after, ["other zone", "leave callback", "join"])
    }
}

private actor HeldParticipantOperation {
    enum Failure: Error { case native }
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var events: [String] = []
    func hold(started: @Sendable () -> Void) async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; started() }
    }
    func record(_ event: String) { events.append(event) }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
