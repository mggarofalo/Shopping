import XCTest
@testable import ShoppingWatch

@MainActor
final class WatchAssociationStatusTests: XCTestCase {
    func testPendingAndFailureClearOnSuccessAndNotifyOnlyWhenChanged() async {
        let status = WatchAssociationStatus()
        var changes = 0
        status.onChange = { changes += 1 }
        await status.refresh { 2 }
        XCTAssertEqual(status.state, .pending)
        await status.refresh { 1 }
        XCTAssertEqual(changes, 1)
        await status.refresh { 0 }
        XCTAssertNil(status.message)
        await status.refresh { throw Injected.failure }
        XCTAssertEqual(status.state, .failed)
        await status.refresh { 0 }
        XCTAssertNil(status.message)
        XCTAssertEqual(changes, 4)
    }

    func testAssociationRecoveryPreservesUnrelatedMessagesAndCloudFailurePriority() async {
        let status = WatchAssociationStatus()
        await status.refresh { throw Injected.failure }
        let history = "Saved data is available. Recent changes could not be refreshed."
        let invitation = "The household invitation could not be accepted."
        for message in [history, invitation] {
            XCTAssertEqual(status.projectedMessage(cloudStatus: .init(), cachedAccount: false, otherMessage: message), message)
            await status.refresh { 0 }
            XCTAssertEqual(status.projectedMessage(cloudStatus: .init(), cachedAccount: false, otherMessage: message), message)
        }
        var cloud = CloudSyncStatus()
        cloud.record(.init(store: "private", operation: .upload, started: .distantPast, ended: Date(), failure: .quota))
        XCTAssertEqual(status.projectedMessage(cloudStatus: cloud, cachedAccount: false, otherMessage: invitation), cloud.message)
        XCTAssertTrue(status.projectedMessage(cloudStatus: .init(), cachedAccount: true, otherMessage: invitation).contains("Using saved data"))
    }

    func testPrivateCloudSuccessDoesNotClearGenuineAssociationFailure() async {
        let status = WatchAssociationStatus()
        await status.refresh { throw Injected.failure }
        var cloud = CloudSyncStatus()
        cloud.record(.init(store: "private", operation: .upload, started: .distantPast, ended: Date(), failure: nil))
        XCTAssertEqual(status.projectedMessage(cloudStatus: cloud, cachedAccount: false, otherMessage: nil), status.message)
        XCTAssertEqual(status.state, .failed)
    }

    func testResetRejectsSuspendedOldRuntimeCompletion() async {
        let status = WatchAssociationStatus()
        let gate = Gate()
        let task = Task { await status.refresh { await gate.wait(); return 1 } }
        await gate.waitUntilStarted()
        status.reset()
        await gate.release()
        await task.value
        XCTAssertNil(status.message)
    }

    func testOlderRefreshCannotOverwriteNewerSuccessfulResult() async {
        let status = WatchAssociationStatus()
        let gate = Gate()
        let old = Task { await status.refresh { await gate.wait(); throw Injected.failure } }
        await gate.waitUntilStarted()
        await status.refresh { 0 }
        await gate.release()
        await old.value
        XCTAssertNil(status.message)
    }

    private enum Injected: Error { case failure }
    private actor Gate {
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var waiter: CheckedContinuation<Void, Never>?
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func wait() async {
            started = true
            await withCheckedContinuation { continuation in
                waiter = continuation
                startWaiter?.resume(); startWaiter = nil
            }
        }
        func release() { waiter?.resume(); waiter = nil }
    }
}
