import Combine
import XCTest

@MainActor
final class FixtureReadinessTests: XCTestCase {
    private final class Witnesses: ObservableObject {
        @Published var selectedHome = "expected-home"
        @Published var account = "expected-account"
        @Published var acknowledgement = false
        @Published var saved = false

        func missing() -> [String] {
            [
                FixtureReadiness.mismatch("Home", actual: selectedHome, expected: "expected-home"),
                FixtureReadiness.mismatch("account", actual: account, expected: "expected-account"),
                FixtureReadiness.mismatch("durable acknowledgement", actual: acknowledgement, expected: true),
                FixtureReadiness.mismatch("saved record", actual: saved, expected: true)
            ].compactMap { $0 }
        }
    }

    func testSelectionCannotReleaseNextActionBeforeAcknowledgementAndSave() async throws {
        let witnesses = Witnesses()
        let observing = expectation(description: "barrier evaluated before held completions")
        var observed = false, nextActionRan = false
        let task = Task {
            try await FixtureReadiness.wait(changes: [witnesses.objectWillChange.eraseToAnyPublisher()]) {
                if !observed { observed = true; observing.fulfill() }
                return witnesses.missing()
            }
            nextActionRan = true
        }
        await fulfillment(of: [observing], timeout: 2)
        XCTAssertFalse(nextActionRan)
        XCTAssertEqual(witnesses.missing().count, 2)
        witnesses.acknowledgement = true
        XCTAssertFalse(witnesses.missing().isEmpty, "Acknowledgement alone cannot bypass the held save")
        witnesses.saved = true
        try await task.value
        XCTAssertTrue(nextActionRan)
    }

    func testStaleAcknowledgementCannotAuthorizeAnotherHomeOrAccount() async throws {
        let witnesses = Witnesses()
        witnesses.acknowledgement = true
        witnesses.saved = true
        witnesses.selectedHome = "new-home"
        witnesses.account = "new-account"
        do {
            try await FixtureReadiness.wait(changes: [], timeout: .zero, missing: witnesses.missing)
            XCTFail("Stale completion cannot authorize a changed identity")
        } catch let error as FixtureReadiness.Timeout {
            XCTAssertEqual(error.missing.count, 2)
            XCTAssertTrue(error.description.contains("expected-home"))
            XCTAssertTrue(error.description.contains("new-account"))
        }
    }

    func testMissingAcknowledgementFailsWithExactPrerequisite() async throws {
        let witnesses = Witnesses()
        witnesses.saved = true
        do {
            try await FixtureReadiness.wait(changes: [], timeout: .zero, missing: witnesses.missing)
            XCTFail("A visible selected Home is insufficient")
        } catch let error as FixtureReadiness.Timeout {
            XCTAssertEqual(error.missing, ["durable acknowledgement: expected true, observed false"])
        }
    }

    func testCancellationNeverRunsNextActionEvenWithReadyWitnesses() async throws {
        let witnesses = Witnesses()
        let observing = expectation(description: "waiting")
        var observed = false
        let task = Task {
            try await FixtureReadiness.wait(changes: [witnesses.objectWillChange.eraseToAnyPublisher()]) {
                if !observed { observed = true; observing.fulfill() }
                return witnesses.missing()
            }
        }
        await fulfillment(of: [observing], timeout: 2)
        task.cancel()
        witnesses.saved = true
        witnesses.acknowledgement = true
        do { try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testFailedCompletionPropagatesInsteadOfTimingOut() async throws {
        enum Failure: Error { case save }
        do {
            try await FixtureReadiness.wait(changes: []) { throw Failure.save }
            XCTFail("Save failure must propagate")
        } catch { XCTAssertTrue(error is Failure) }
    }

    func testCompletionBetweenFirstInspectionAndSubscriptionIsNotLost() async throws {
        var inspections = 0
        try await FixtureReadiness.wait(changes: []) {
            inspections += 1
            // Simulate the first snapshot missing an acknowledgement that has
            // completed by registration, without emitting another notification.
            return inspections == 1 ? ["acknowledgement not in first snapshot"] : []
        }
        XCTAssertEqual(inspections, 2)
    }

    func testFailureAfterSubscriptionPropagates() async throws {
        enum Failure: Error { case save }
        let changes = PassthroughSubject<Void, Never>()
        let observing = expectation(description: "waiting before save fails")
        var observed = false, failed = false
        let task = Task {
            try await FixtureReadiness.wait(changes: [changes.eraseToAnyPublisher()]) {
                if failed { throw Failure.save }
                if !observed { observed = true; observing.fulfill() }
                return ["save incomplete"]
            }
        }
        await fulfillment(of: [observing], timeout: 2)
        failed = true
        changes.send(())
        do { try await task.value; XCTFail("A failed completion must propagate") }
        catch { XCTAssertTrue(error is Failure) }
    }

    func testAlreadyCompleteFixtureDoesNotNeedAnotherNotification() async throws {
        let witnesses = Witnesses()
        witnesses.saved = true
        witnesses.acknowledgement = true
        try await FixtureReadiness.wait(changes: [], timeout: .zero, missing: witnesses.missing)
    }
}
