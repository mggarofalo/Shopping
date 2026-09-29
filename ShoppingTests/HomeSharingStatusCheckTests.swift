import XCTest
@testable import Shopping

@MainActor
final class HomeSharingStatusCheckTests: XCTestCase {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { opened = false; return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            if let continuation { self.continuation = nil; continuation.resume() }
            else { opened = true }
        }
    }
    private enum Failure: Error { case expected }

    private func drained(_ check: HomeSharingStatusCheck<Int>) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while check.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(check.isRunning)
    }

    func testTimeoutEndsWaitingButHeldOperationPreventsDuplicateUntilItDrains() async throws {
        let deadline = Gate(), work = Gate(), started = expectation(description: "work started")
        let check = HomeSharingStatusCheck<Int>(waitForDeadline: { await deadline.wait() })
        let task = Task { await check.run { started.fulfill(); await work.wait(); return 7 } }
        await fulfillment(of: [started], timeout: 2)
        await deadline.open()
        guard case .timedOut = await task.value else { return XCTFail("Must return at the presentation deadline") }
        XCTAssertTrue(check.isRunning)
        guard case .alreadyRunning = await check.run({ XCTFail("Duplicate read"); return 8 }) else {
            return XCTFail("Uncooperative work must retain its reservation")
        }
        await work.open()
        try await drained(check)
        guard case .value(9) = await check.run({ 9 }) else { return XCTFail("A completed drain must allow a new check") }
    }

    func testCancellationEndsCallerWaitWithoutAcceptingLateResult() async throws {
        let work = Gate(), started = expectation(description: "work started")
        let check = HomeSharingStatusCheck<Int>()
        let task = Task { await check.run { started.fulfill(); await work.wait(); return 1 } }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        guard case .cancelled = await task.value else { return XCTFail("Cancellation should release the UI") }
        XCTAssertTrue(check.isRunning)
        await work.open()
        try await drained(check)
    }

    func testRetiringScopeCancelsPresentationButDoesNotOverlapAnOldRead() async throws {
        let work = Gate(), started = expectation(description: "work started")
        let check = HomeSharingStatusCheck<Int>()
        let task = Task { await check.run { started.fulfill(); await work.wait(); return 1 } }
        await fulfillment(of: [started], timeout: 2)
        check.invalidate()
        guard case .cancelled = await task.value else { return XCTFail("Retired scope must release the UI") }
        guard case .alreadyRunning = await check.run({ 2 }) else { return XCTFail("Old writer must drain first") }
        await work.open()
        try await drained(check)
        guard case .value(3) = await check.run({ 3 }) else { return XCTFail("Fresh scope should be readable") }
    }

    func testFailureIsRecoverableAndDoesNotLeaveBusyReservation() async {
        let check = HomeSharingStatusCheck<Int>()
        guard case .failed = await check.run({ throw Failure.expected }) else { return XCTFail("Failure must be explicit") }
        XCTAssertFalse(check.isRunning)
        guard case .value(4) = await check.run({ 4 }) else { return XCTFail("Failure must permit retry") }
    }

    func testCompletedReadCannotBeReplacedByALateDeadline() async {
        let deadline = Gate()
        let check = HomeSharingStatusCheck<Int>(waitForDeadline: { await deadline.wait() })
        guard case .value(5) = await check.run({ 5 }) else { return XCTFail("Completed observation expected") }
        await deadline.open()
        XCTAssertFalse(check.isRunning)
        guard case .value(6) = await check.run({ 6 }) else { return XCTFail("Late deadline must not claim the next request") }
    }
}
