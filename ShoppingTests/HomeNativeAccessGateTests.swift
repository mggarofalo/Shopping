import CloudKit
import XCTest
@testable import Shopping

final class HomeNativeAccessGateTests: XCTestCase {
    private actor HeldNativePass {
        let gate: HomeNativeAccessGate
        let home: HomeNativeAccessIdentity
        let started: XCTestExpectation
        private(set) var count = 0
        private var release: CheckedContinuation<Void, Never>?
        private var firstReleased = false
        init(gate: HomeNativeAccessGate, home: HomeNativeAccessIdentity, started: XCTestExpectation) {
            self.gate = gate; self.home = home; self.started = started
        }
        func run() async -> String? {
            count += 1
            let request = gate.begin(home)
            if count == 1, !firstReleased {
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
            return gate.finish(request, access: .writable) ? nil : "Stale observation"
        }
        func finishFirst() { firstReleased = true; release?.resume(); release = nil }
    }

    private func identity(account: String = "A", store: String = "shared", root: String = "root",
                          share: String = "share", homeID: UUID = UUID(), listID: UUID = UUID()) throws -> HomeNativeAccessIdentity {
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.nativeaccess",
            environment: "Development", accountRecordName: account)
        return HomeNativeAccessIdentity(scope: HomeEffectScope(session: session, householdID: homeID, listID: listID),
            storeIdentifier: store, rootURI: root,
            share: HomeEffectShare(recordName: share, zoneName: "zone", zoneOwnerName: "owner"))
    }

    func testPublicationRequiresVerificationAndTransientRefreshWithholdsIt() throws {
        let gate = HomeNativeAccessGate(), home = try identity()
        XCTAssertFalse(gate.permitsPublication(home))
        let first = gate.begin(home)
        XCTAssertTrue(gate.finish(first, access: .writable))
        XCTAssertTrue(gate.permitsPublication(home))
        _ = gate.begin(home) // A request that fails on the network supplies no observation.
        XCTAssertFalse(gate.permitsPublication(home))
        XCTAssertEqual(gate.observedAccess(home), .writable, "A network failure is not observed read-only or loss")
    }

    func testNewerReadOnlyObservationRejectsDelayedWritableCompletion() throws {
        let gate = HomeNativeAccessGate(), home = try identity()
        let oldWritable = gate.begin(home)
        let newer = gate.begin(home)
        try gate.restrict(newer, to: .readOnly)
        XCTAssertFalse(gate.finish(oldWritable, access: .writable))
        XCTAssertTrue(gate.finish(newer, access: .readOnly))
        XCTAssertFalse(gate.permitsPublication(home))
        XCTAssertEqual(gate.observedAccess(home), .readOnly)
        XCTAssertThrowsError(try gate.restrict(oldWritable, to: .lost))
    }

    func testFailedDurableRestrictionRemainsConservativeAndInvalidationFencesCallbacks() throws {
        let gate = HomeNativeAccessGate(), home = try identity()
        let pending = gate.begin(home)
        try gate.restrict(pending, to: .lost)
        // No finish: the durable write failed. The observed restriction still applies.
        XCTAssertEqual(gate.observedAccess(home), .lost)
        XCTAssertFalse(gate.permitsPublication(home))
        gate.invalidateVerification()
        XCTAssertFalse(gate.finish(pending, access: .writable))
        XCTAssertEqual(gate.observedAccess(home), .lost)
    }

    func testPermissionCannotTransferToAnotherAccountStoreRootOrShare() throws {
        let gate = HomeNativeAccessGate(), homeID = UUID(), listID = UUID()
        let original = try identity(homeID: homeID, listID: listID)
        XCTAssertTrue(gate.finish(gate.begin(original), access: .writable))
        for other in [try identity(account: "B", homeID: homeID, listID: listID),
                      try identity(store: "replacement", homeID: homeID, listID: listID),
                      try identity(root: "reimport", homeID: homeID, listID: listID),
                      try identity(share: "replacement", homeID: homeID, listID: listID)] {
            XCTAssertFalse(gate.permitsPublication(other))
        }
    }

    func testNativeVersionDeduplicatesAcrossDevicesAndKeepsWritableBoundarySpecific() throws {
        let homeID = UUID(), listID = UUID()
        let a = try identity(homeID: homeID, listID: listID)
        let b = try identity(store: "second-device", root: "second-root", homeID: homeID, listID: listID)
        let readOnly = ManagedHomeAccessObserver.Observation(access: .readOnly, changeTag: "version-1")
        let first = ManagedHomeAccessObserver.operationID(identity: a, observation: readOnly, boundary: [])
        XCTAssertEqual(first, ManagedHomeAccessObserver.operationID(identity: b, observation: readOnly, boundary: [UUID()]))
        XCTAssertNotEqual(first, ManagedHomeAccessObserver.operationID(identity: a,
            observation: .init(access: .readOnly, changeTag: "version-2"), boundary: []))
        let writable = ManagedHomeAccessObserver.Observation(access: .writable, changeTag: "version-3")
        XCTAssertNotEqual(ManagedHomeAccessObserver.operationID(identity: a, observation: writable, boundary: []),
            ManagedHomeAccessObserver.operationID(identity: a, observation: writable, boundary: [UUID()]))
    }

    func testOnlyScopedNativeMissingPermissionErrorsClassifyAsKnownShareLoss() {
        for code in [CKError.Code.unknownItem, .permissionFailure, .zoneNotFound] {
            XCTAssertTrue(ManagedHomeAccessObserver.isKnownShareLoss(CKError(code)))
        }
        for code in [CKError.Code.networkUnavailable, .networkFailure, .notAuthenticated, .serviceUnavailable,
                     .partialFailure, .badContainer, .badDatabase, .operationCancelled, .participantMayNeedVerification] {
            XCTAssertFalse(ManagedHomeAccessObserver.isKnownShareLoss(CKError(code)))
        }
        XCTAssertFalse(ManagedHomeAccessObserver.isKnownShareLoss(PersonalCartError.unavailable))
    }

    func testNativeLossSurvivesDelayedEarlierGrantAndLaterExplicitRejoin() throws {
        let home = try identity()
        let earlierLoss = try XCTUnwrap(ManagedHomeAccessObserver.record(.init(access: .lost, changeTag: nil),
            identity: home, access: HomeEffectAccess(records: []), capturedRestrictionIDs: []))
        let earlierGrant = HomeAccessRecord(id: UUID(), scope: home.scope, share: home.share,
            action: .joined(observedBlockIDs: [earlierLoss.id]))
        let observed = ManagedHomeAccessObserver.Observation(access: .lost, changeTag: nil)
        let partial = try HomeEffectAccess(records: [earlierLoss])
        XCTAssertTrue(partial.requiresExplicitRejoin)
        let freshLoss = try XCTUnwrap(ManagedHomeAccessObserver.record(observed, identity: home,
            access: partial, capturedRestrictionIDs: []))
        XCTAssertNotEqual(freshLoss.id, earlierLoss.id, "A distinct native loss must not reuse the earlier loss identity")
        let afterLoss = try HomeEffectAccess(records: [earlierLoss, freshLoss])
        XCTAssertEqual(freshLoss, try ManagedHomeAccessObserver.record(observed, identity: home,
            access: afterLoss, capturedRestrictionIDs: []), "Repeated native loss must not create a write loop")
        let priorAuthority = HomeEffectAuthority(observedBlockIDs: [earlierLoss.id], grantID: earlierGrant.id)
        let imported = try HomeEffectAccess(records: [earlierLoss, freshLoss, earlierGrant])
        XCTAssertFalse(imported.permitsPublication(priorAuthority))
        let laterGrant = HomeAccessRecord(id: UUID(), scope: home.scope, share: home.share,
            action: .joined(observedBlockIDs: imported.blockIDs))
        let rejoined = try HomeEffectAccess(records: imported.records + [laterGrant])
        XCTAssertTrue(rejoined.permitsPublication(rejoined.capturedAuthority))
        XCTAssertFalse(rejoined.permitsPublication(priorAuthority), "A later rejoin must not revive the earlier membership's effects")
    }

    func testNativeWritableObservationCannotResolveNewerRestrictionOrGrantMembership() throws {
        let home = try identity()
        let loss = HomeAccessRecord(id: UUID(), scope: home.scope, share: home.share, action: .blocked(.revoked))
        let restriction = HomeAccessRecord(id: UUID(), scope: home.scope, share: home.share, action: .readOnly)
        let access = try HomeEffectAccess(records: [loss, restriction])
        let writable = ManagedHomeAccessObserver.Observation(access: .writable, changeTag: "current")
        XCTAssertThrowsError(try ManagedHomeAccessObserver.record(writable, identity: home,
            access: access, capturedRestrictionIDs: []))
        let resolution = try XCTUnwrap(ManagedHomeAccessObserver.record(writable, identity: home,
            access: access, capturedRestrictionIDs: [restriction.id]))
        let resolved = try HomeEffectAccess(records: access.records + [resolution])
        XCTAssertTrue(resolved.unresolvedRestrictionIDs.isEmpty)
        XCTAssertTrue(resolved.requiresExplicitRejoin)
        XCTAssertFalse(resolved.permitsPublication(resolved.capturedAuthority))
    }

    func testAccessOnlyImportPreservesNativeVerificationForBothHomes() throws {
        let gate = HomeNativeAccessGate()
        let homeA = try identity(root: "home-A", share: "share-A")
        let homeB = try identity(root: "home-B", share: "share-B")
        let requestA = gate.begin(homeA), requestB = gate.begin(homeB)
        XCTAssertTrue(gate.finish(requestA, access: .writable))
        XCTAssertTrue(gate.finish(requestB, access: .writable))

        // Imported loss/permission facts for A remain enforced by the private
        // ledger; they must not silently invalidate B's native verification.
        gate.applyImportedHistory(.init(transactionCount: 1, requiresAccessRefresh: false))
        XCTAssertTrue(gate.isCurrent(requestA))
        XCTAssertTrue(gate.isCurrent(requestB))
        XCTAssertTrue(gate.permitsPublication(homeA))
        XCTAssertTrue(gate.permitsPublication(homeB))
    }

    func testAccessOnlyImportPreservesHeldNativeCompletionWithoutSchedulingAnotherPass() async throws {
        let queue = HomeAccessRefreshQueue(), gate = HomeNativeAccessGate()
        let homeA = try identity(root: "home-A", share: "share-A")
        let homeB = try identity(root: "home-B", share: "share-B")
        XCTAssertTrue(gate.finish(gate.begin(homeB), access: .writable))
        let started = expectation(description: "Native verification held during access-only import")
        let native = HeldNativePass(gate: gate, home: homeA, started: started)
        let pending = Task { await queue.run(recheckIfRunning: false) { await native.run() } }
        await fulfillment(of: [started], timeout: 2)
        gate.applyImportedHistory(.init(transactionCount: 1, requiresAccessRefresh: false))
        XCTAssertFalse(gate.permitsPublication(homeA), "An unfinished read is still unverified")
        XCTAssertTrue(gate.permitsPublication(homeB))
        // Access-only history deliberately queues no native recheck. Its callback
        // must remain current or A would stay blocked until another foreground.
        await native.finishFirst()
        let failure = await pending.value
        let passes = await native.count
        XCTAssertNil(failure)
        XCTAssertEqual(passes, 1)
        XCTAssertTrue(gate.permitsPublication(homeA))
        XCTAssertTrue(gate.permitsPublication(homeB))
    }

    func testOrdinaryImportDuringHeldNativePassQueuesFreshVerification() async throws {
        let queue = HomeAccessRefreshQueue(), gate = HomeNativeAccessGate(), home = try identity()
        let otherHome = try identity(root: "other-home", share: "other-share")
        XCTAssertTrue(gate.finish(gate.begin(otherHome), access: .writable))
        let started = expectation(description: "Native verification held")
        let native = HeldNativePass(gate: gate, home: home, started: started)
        let first = Task { await queue.run(recheckIfRunning: false) { await native.run() } }
        await fulfillment(of: [started], timeout: 2)
        gate.applyImportedHistory(.init(transactionCount: 1, requiresAccessRefresh: true))
        XCTAssertFalse(gate.permitsPublication(home), "Ordinary domain imports still require fresh native verification")
        XCTAssertFalse(gate.permitsPublication(otherHome), "Previously verified homes are invalidated for a domain import")
        let imported = Task { await queue.run(recheckIfRunning: true) { await native.run() } }
        let deadline = ContinuousClock.now + .seconds(2)
        while await queue.pendingRequestCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        let pending = await queue.pendingRequestCount
        XCTAssertEqual(pending, 1)
        await native.finishFirst()
        let firstFailure = await first.value, importedFailure = await imported.value
        XCTAssertNil(firstFailure)
        XCTAssertNil(importedFailure)
        let passes = await native.count
        XCTAssertEqual(passes, 2)
        XCTAssertTrue(gate.permitsPublication(home), "The invalidated pass must be replaced without another user action")
    }

    func testConcurrentForegroundReadersShareOneNativePass() async throws {
        let queue = HomeAccessRefreshQueue(), gate = HomeNativeAccessGate(), home = try identity()
        let started = expectation(description: "Shared native pass held")
        let native = HeldNativePass(gate: gate, home: home, started: started)
        let first = Task { await queue.run(recheckIfRunning: false) { await native.run() } }
        await fulfillment(of: [started], timeout: 2)
        let readers = (0..<8).map { _ in Task { await queue.run(recheckIfRunning: false) { await native.run() } } }
        let deadline = ContinuousClock.now + .seconds(2)
        while await queue.pendingRequestCount < readers.count, ContinuousClock.now < deadline { await Task.yield() }
        let pending = await queue.pendingRequestCount
        XCTAssertEqual(pending, readers.count)
        await native.finishFirst()
        let result = await first.value
        XCTAssertNil(result)
        for reader in readers { let result = await reader.value; XCTAssertNil(result) }
        let passes = await native.count
        XCTAssertEqual(passes, 1)
    }
}
