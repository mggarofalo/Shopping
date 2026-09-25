import CoreData
import XCTest
@testable import Shopping

final class ShareAssociationRetryTests: XCTestCase {
    private let household = URL(string: "x-coredata://household")!
    private let item = URL(string: "x-coredata://item")!

    private func journal() throws -> FileShareAssociationJournal {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        try JSONEncoder().encode([PendingShareAssociation(householdURI: household, objectURIs: [item])]).write(to: url)
        return FileShareAssociationJournal(url: url)
    }

    func testUnsharedHouseholdRemainsDurableWithoutPendingWarningAndCanBeSharedLater() async throws {
        let journal = try journal()
        let gate = PassGate()
        let household = household, item = item
        let worker = ManagedShareAssociationWorker(journal: journal) {
            if await gate.isShared {
                try journal.acknowledge(householdURI: household, objectURIs: [item])
                return []
            }
            return [household]
        }
        let unshared = try await worker.retryPending()
        XCTAssertEqual(unshared, 0)
        XCTAssertEqual(try journal.pending(), [.init(householdURI: household, objectURIs: [item])])
        await gate.share()
        let shared = try await worker.retryPending()
        XCTAssertEqual(shared, 0)
        XCTAssertTrue(try journal.pending().isEmpty)
    }

    func testExistingShareWorkCountsAndErrorsDoNotDropJournal() async throws {
        let journal = try journal()
        let worker = ManagedShareAssociationWorker(journal: journal) { [] }
        let count = try await worker.retryPending()
        XCTAssertEqual(count, 1)
        let failed = ManagedShareAssociationWorker(journal: journal) { throw Injected.failure }
        do { _ = try await failed.retryPending(); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error is Injected) }
        XCTAssertEqual(try journal.pending().first?.objectURIs, [item])
    }

    func testOverlappingRetriesSerializeAndBothObserveFinalPass() async throws {
        let journal = try journal()
        let gate = PassGate()
        let household = household
        let worker = ManagedShareAssociationWorker(journal: journal) {
            await gate.pass()
            return [household]
        }
        let first = Task { try await worker.retryPending() }
        await gate.waitUntilStarted()
        let second = Task { try await worker.retryPending() }
        var queued = false
        for _ in 0..<1_000 {
            if await worker.queuedRetryCount == 1 { queued = true; break }
            await Task.yield()
        }
        XCTAssertTrue(queued, "The second retry must overlap the suspended first pass")
        await gate.release()
        let firstCount = try await first.value
        let secondCount = try await second.value
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 0)
        let passes = await gate.passes
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(try journal.pending().first?.objectURIs, [item])
    }

    private enum Injected: Error { case failure }
    private actor PassGate {
        var isShared = false
        var passes = 0
        private var started: CheckedContinuation<Void, Never>?
        private var pending: CheckedContinuation<Void, Never>?
        func share() { isShared = true }
        func waitUntilStarted() async {
            if passes > 0 { return }
            await withCheckedContinuation { started = $0 }
        }
        func pass() async {
            passes += 1
            guard passes == 1 else { return }
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume(); started = nil
            }
        }
        func release() { pending?.resume(); pending = nil }
    }
}
