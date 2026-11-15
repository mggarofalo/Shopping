import CoreData
import XCTest
@testable import Shopping

/// SHOPPING-277 evidence, not a regression gate. Run under simlock with
/// TEST_RUNNER_SHOPPING_CART_TIMING=1. Prints tap to Remove-enabled and to
/// Checkout-enabled with a 500-need cart history while a simulated mirroring
/// export repeatedly holds the persistent store coordinator.
@MainActor
final class PersonalCartCommitTimingTests: XCTestCase {
    private struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    func testCartCommitTimingWithLargeHistoryUnderCoordinatorContention() async throws {
        guard ProcessInfo.processInfo.environment["SHOPPING_CART_TIMING"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SHOPPING_CART_TIMING=1 to measure")
        }
        let historyCount = 500
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let ids = try (0...historyCount).map {
            try needs.addOneTimeNeed(title: "Item \($0)", householdID: scope.householdID, listID: scope.listID)
        }
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.timing-tests", environment: "Development", accountRecordName: "alice"))
        let cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
        try writeHistory(cart, needIDs: Array(ids.prefix(historyCount)), householdID: scope.householdID, listID: scope.listID)
        let target = ids[historyCount]

        let presentation = PersonalCartPresentation(service: cart, householdID: scope.householdID, listID: scope.listID)
        let loaded = await waitUntil(timeout: .seconds(120)) { presentation.hasLoadedSnapshot }
        XCTAssertTrue(loaded)
        let contention = ContentionLoop(coordinator: persistence.container.persistentStoreCoordinator)
        contention.start()
        defer { contention.stop() }

        let start = ContinuousClock.now
        let adding = Task { try await presentation.cart(target) }
        let removable = await waitUntil(timeout: .seconds(900)) {
            presentation.entries.contains { $0.needID == target } && !presentation.isCartTransitionPending(target)
        }
        let removeReady = ContinuousClock.now - start
        let checkoutable = await waitUntil(timeout: .seconds(900)) {
            !presentation.entries.isEmpty && !presentation.entries.contains {
                presentation.isCartTransitionPending($0.needID) || presentation.isQuantityTransitionPending($0.id)
            }
        }
        let checkoutReady = ContinuousClock.now - start
        try await adding.value
        let addReturned = ContinuousClock.now - start
        XCTAssertTrue(removable && checkoutable)
        let entry = try XCTUnwrap(presentation.entries.first { $0.needID == target })
        let removeStart = ContinuousClock.now
        let remove = Task { try await presentation.uncart(entry) }
        let cleared = await waitUntil(timeout: .seconds(900)) {
            !presentation.entries.contains { $0.needID == target } && !presentation.isCartTransitionPending(target)
        }
        let removeCleared = ContinuousClock.now - removeStart
        try await remove.value
        XCTAssertTrue(cleared)
        let line = "SHOPPING-277 timing history=\(historyCount) removeEnabled=\(removeReady) "
            + "checkoutEnabled=\(checkoutReady) addReturned=\(addReturned) removeCleared=\(removeCleared)"
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "SHOPPING-277 cart commit timing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One add and one remove per need, written as the commands write them, in a
    /// single transaction so setup does not dominate the lock hold.
    private func writeHistory(_ cart: PersonalCartService, needIDs: [UUID], householdID: UUID, listID: UUID) throws {
        try cart.transact { repository in
            for needID in needIDs {
                let need = try XCTUnwrap(repository.need(needID, householdID: householdID, listID: listID))
                let added = UUID(), removed = UUID()
                let snapshot = try PersonalCartSnapshotBuilder.make(need: need, session: repository.session,
                    generation: UUID(), evidence: [added], quantity: need.quantity, homeEffectAuthority: .legacy)
                try repository.insert(id: added, kind: "cart",
                    command: PersonalCartCommand.cart(needID: needID, householdID: householdID, listID: listID),
                    value: PersonalCartCommandResult(edit: PersonalCartEdit(id: added, action: .add,
                        snapshot: snapshot, ancestors: []), skipped: false))
                let token = snapshot.token
                let after = PersonalCartEntrySnapshot(title: snapshot.title, quantity: snapshot.quantity,
                    notes: snapshot.notes, categoryID: snapshot.categoryID, categoryName: snapshot.categoryName,
                    categoryOrder: snapshot.categoryOrder, urgency: snapshot.urgency, anyStore: snapshot.anyStore,
                    storeIDs: snapshot.storeIDs, purchaseRulesResolved: snapshot.purchaseRulesResolved,
                    token: PersonalCartEntryToken(accountBinding: token.accountBinding, householdID: householdID,
                        listID: listID, needID: needID, generation: token.generation,
                        evidence: token.evidence.union([removed]), homeEffectAuthority: token.homeEffectAuthority),
                    purchaseNotices: snapshot.purchaseNotices, demandAvailable: snapshot.demandAvailable)
                try repository.insert(id: removed, kind: "cart", command: PersonalCartCommand.uncart(token),
                    value: PersonalCartCommandResult(edit: PersonalCartEdit(id: removed, action: .remove,
                        snapshot: after, ancestors: token.evidence), skipped: false))
            }
        }
    }

    private func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// Simulated mirroring: holds the coordinator 20 ms out of every 30 ms.
private final class ContentionLoop: @unchecked Sendable {
    private let coordinator: NSPersistentStoreCoordinator
    private let lock = NSLock()
    private var running = false
    private let finished = DispatchSemaphore(value: 0)

    init(coordinator: NSPersistentStoreCoordinator) { self.coordinator = coordinator }

    func start() {
        lock.withLock { running = true }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                coordinator.performAndWait { Thread.sleep(forTimeInterval: 0.020) }
                Thread.sleep(forTimeInterval: 0.010)
            }
            finished.signal()
        }
    }

    func stop() {
        lock.withLock { running = false }
        finished.wait()
    }
}
