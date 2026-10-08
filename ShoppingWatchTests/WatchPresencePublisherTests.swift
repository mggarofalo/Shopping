import XCTest
@testable import ShoppingWatch

@MainActor
final class WatchPresencePublisherTests: XCTestCase {
    /// Intentionally ignores cancellation so invalidation tests also exercise
    /// late callbacks from work that cannot be stopped once it has begun.
    private final class Gate {
        var starts = 0
        var onStart: ((Int) -> Void)?
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                starts += 1
                continuations.append(continuation)
                onStart?(starts)
            }
        }

        func release() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume()
        }
    }

    func testRepeatedNeedsShareFirstWindowWithoutPostponingPublication() async {
        let delay = Gate(), window = expectation(description: "First window")
        let published = expectation(description: "Coalesced publication")
        delay.onStart = { _ in window.fulfill() }
        let first = UUID(), second = UUID()
        var batches: [Set<UUID>] = []
        var requestedDelays: [Duration] = []
        let publisher = WatchPresencePublisher(sleep: { duration in
            requestedDelays.append(duration)
            await delay.wait()
        }, publish: { needs in
            batches.append(needs)
            published.fulfill()
            return needs
        })
        publisher.markDirty(first)
        await fulfillment(of: [window], timeout: 2)
        for _ in 0..<50 { publisher.markDirty(first) }
        publisher.markDirty(second)
        publisher.retry()
        XCTAssertEqual(delay.starts, 1, "Further edits must not restart the first deadline")
        XCTAssertEqual(requestedDelays, [.seconds(2)])
        delay.release()
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(batches, [[first, second]])
        XCTAssertTrue(publisher.dirtyNeedIDs.isEmpty)
        XCTAssertFalse(publisher.hasScheduledPublication)
    }

    func testEditDuringHeldPublicationSurvivesOlderAcknowledgment() async {
        let delay = Gate(), publication = Gate()
        let firstWindow = expectation(description: "First window")
        let firstBatch = expectation(description: "First batch held")
        let trailingWindow = expectation(description: "New edit's window")
        let finished = expectation(description: "New state published")
        delay.onStart = { count in (count == 1 ? firstWindow : trailingWindow).fulfill() }
        publication.onStart = { _ in firstBatch.fulfill() }
        let need = UUID()
        var batches: [Set<UUID>] = []
        let publisher = WatchPresencePublisher(sleep: { _ in await delay.wait() }, publish: { needs in
            batches.append(needs)
            if batches.count == 1 { await publication.wait() }
            else { finished.fulfill() }
            return needs
        })
        publisher.markDirty(need)
        await fulfillment(of: [firstWindow], timeout: 2)
        delay.release()
        await fulfillment(of: [firstBatch], timeout: 2)
        publisher.markDirty(need)
        publication.release()
        await fulfillment(of: [trailingWindow], timeout: 2)
        XCTAssertEqual(publisher.dirtyNeedIDs, [need])
        XCTAssertEqual(batches.count, 1)
        delay.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(batches, [[need], [need]])
        XCTAssertTrue(publisher.dirtyNeedIDs.isEmpty)
        XCTAssertFalse(publisher.hasScheduledPublication)
    }

    func testFailedNeedDoesNotBlockOthersAndWaitsForExplicitRetry() async {
        let delay = Gate()
        let firstWindow = expectation(description: "First window")
        let retryWindow = expectation(description: "Requested retry window")
        let firstBatch = expectation(description: "Partial success")
        let retryBatch = expectation(description: "Retry success")
        delay.onStart = { count in (count == 1 ? firstWindow : retryWindow).fulfill() }
        let failed = UUID(), succeeded = UUID()
        var batches: [Set<UUID>] = []
        let publisher = WatchPresencePublisher(sleep: { _ in await delay.wait() }, publish: { needs in
            batches.append(needs)
            if batches.count == 1 { firstBatch.fulfill(); return [succeeded] }
            retryBatch.fulfill()
            return needs
        })
        publisher.markDirty(failed)
        publisher.markDirty(succeeded)
        await fulfillment(of: [firstWindow], timeout: 2)
        delay.release()
        await fulfillment(of: [firstBatch], timeout: 2)
        XCTAssertEqual(publisher.dirtyNeedIDs, [failed])
        XCTAssertFalse(publisher.hasScheduledPublication, "An unchanged failure must not spin while idle")
        XCTAssertEqual(delay.starts, 1)
        publisher.retry()
        await fulfillment(of: [retryWindow], timeout: 2)
        delay.release()
        await fulfillment(of: [retryBatch], timeout: 2)
        XCTAssertEqual(batches, [[failed, succeeded], [failed]])
        XCTAssertTrue(publisher.dirtyNeedIDs.isEmpty)
        XCTAssertFalse(publisher.hasScheduledPublication)
    }

    func testInvalidatedBatchCannotAcknowledgeNewScopeWork() async {
        let delay = Gate(), publication = Gate()
        let oldWindow = expectation(description: "Old scope window")
        let oldBatch = expectation(description: "Old scope batch held")
        let newWindow = expectation(description: "New scope window")
        let oldReturned = expectation(description: "Old callback returned")
        let newPublished = expectation(description: "New scope published")
        delay.onStart = { count in (count == 1 ? oldWindow : newWindow).fulfill() }
        publication.onStart = { _ in oldBatch.fulfill() }
        // Reusing the same need ID makes the generation fence necessary even
        // if account-scoped work happens to carry matching domain identifiers.
        let need = UUID()
        var batches = 0
        let publisher = WatchPresencePublisher(sleep: { _ in await delay.wait() }, publish: { needs in
            batches += 1
            if batches == 1 {
                await publication.wait()
                oldReturned.fulfill()
            } else { newPublished.fulfill() }
            return needs
        })
        publisher.markDirty(need)
        await fulfillment(of: [oldWindow], timeout: 2)
        delay.release()
        await fulfillment(of: [oldBatch], timeout: 2)
        publisher.invalidate()
        XCTAssertTrue(publisher.dirtyNeedIDs.isEmpty)
        publisher.markDirty(need)
        await fulfillment(of: [newWindow], timeout: 2)
        publication.release()
        await fulfillment(of: [oldReturned], timeout: 2)
        XCTAssertEqual(publisher.dirtyNeedIDs, [need])
        XCTAssertTrue(publisher.hasScheduledPublication, "Old completion cannot clear the new task")
        delay.release()
        await fulfillment(of: [newPublished], timeout: 2)
        XCTAssertEqual(batches, 2)
        XCTAssertTrue(publisher.dirtyNeedIDs.isEmpty)
    }

    func testInvalidatedSleepingWindowCannotStartPublication() async {
        let delay = Gate(), window = expectation(description: "Window held")
        let returned = expectation(description: "Cancelled sleep returned")
        delay.onStart = { _ in window.fulfill() }
        var batches = 0
        let publisher = WatchPresencePublisher(sleep: { _ in
            await delay.wait()
            returned.fulfill()
        }, publish: { needs in
            batches += 1
            return needs
        })
        publisher.markDirty(UUID())
        await fulfillment(of: [window], timeout: 2)
        publisher.invalidate()
        delay.release()
        XCTAssertTrue(publisher.dirtyNeedIDs.isEmpty)
        XCTAssertFalse(publisher.hasScheduledPublication)
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(batches, 0)
    }

    func testReleasingPublisherCancelsPendingWindowWithoutPublishing() async {
        let delay = Gate(), window = expectation(description: "Window held")
        let cancelled = expectation(description: "Released publisher cancels its sleeper")
        delay.onStart = { _ in window.fulfill() }
        var batches = 0
        var publisher: WatchPresencePublisher? = WatchPresencePublisher(sleep: { _ in
            await delay.wait()
            XCTAssertTrue(Task.isCancelled)
            cancelled.fulfill()
        }, publish: { needs in
            batches += 1
            return needs
        })
        weak var released = publisher
        publisher?.markDirty(UUID())
        await fulfillment(of: [window], timeout: 2)
        publisher = nil
        XCTAssertNil(released, "A sleeping window must not retain its owner")
        delay.release()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(batches, 0)
    }

}
