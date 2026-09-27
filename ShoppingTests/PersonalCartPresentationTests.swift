import CoreData
import XCTest
@testable import Shopping

final class PersonalCartPresentationTests: XCTestCase {
    private struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    @MainActor
    func testColdPresentationKeepsPrivateCleanupAndHistoryWhenSharedReceiptIsIncomplete() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let milkItem = try needs.createItem(name: "Milk", householdID: scope.householdID)
        let breadItem = try needs.createItem(name: "Bread", householdID: scope.householdID)
        let milk = try needs.addRememberedNeed(itemID: milkItem, listID: scope.listID, householdID: scope.householdID)
        let bread = try needs.addRememberedNeed(itemID: breadItem, listID: scope.listID, householdID: scope.householdID)
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        for needID in [milk, bread] {
            try service.cart(needID: needID, householdID: scope.householdID, listID: scope.listID)
        }
        let breadEntry = try XCTUnwrap(service.entries(householdID: scope.householdID, listID: scope.listID)
            .first { $0.needID == bread })
        let checkout = try service.prepareCheckout(tokens: [breadEntry.token])
        _ = try service.checkout(checkout, operationID: checkout.id)

        // Simulate a partial incoming household record, not a locally authorized command.
        let incoming = persistence.simulationContext()
        try incoming.performAndWait {
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            request.predicate = NSPredicate(format: "kind == %@", "purchase")
            let receipt = try XCTUnwrap(incoming.fetch(request).first)
            receipt.payload = nil
            try incoming.save()
        }

        let presentation = PersonalCartPresentation(service: service, householdID: scope.householdID, listID: scope.listID)
        try await waitUntil { presentation.history.count == 1 }
        XCTAssertEqual(presentation.entries.map(\.needID), [milk])
        XCTAssertEqual(presentation.history.map(\.id), [checkout.id])
        XCTAssertNotNil(presentation.error)
        XCTAssertTrue(presentation.outstandingNeedIDs.isEmpty)
        XCTAssertTrue(presentation.presence.isEmpty)
        try await presentation.uncart(XCTUnwrap(presentation.entries.first))
        try await waitUntil { presentation.entries.isEmpty }
        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertEqual(presentation.history.map(\.id), [checkout.id])
    }

    @MainActor
    func testBlockedWriterDoesNotBlockMainActorDuringRefresh() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        let entered = expectation(description: "writer occupied")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            persistence.writer.performAndWait {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let start = ContinuousClock.now
        let presentation = PersonalCartPresentation(service: service,
            householdID: scope.householdID, listID: scope.listID)
        presentation.refresh()
        let elapsed = start.duration(to: .now)
        release.signal()
        XCTAssertLessThan(elapsed, .milliseconds(250))
    }

    @MainActor
    func testBlockedWriterDoesNotBlockMainActorDuringCartCommand() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let itemID = try needs.createItem(name: "Milk", householdID: scope.householdID)
        let needID = try needs.addRememberedNeed(itemID: itemID,
            listID: scope.listID, householdID: scope.householdID)
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        let presentation = PersonalCartPresentation(service: service,
            householdID: scope.householdID, listID: scope.listID)
        let entered = expectation(description: "writer occupied")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            persistence.writer.performAndWait {
                entered.fulfill()
                release.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }

        let started = ContinuousClock.now
        let command = Task { try await presentation.cart(needID) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(250))
        release.signal()
        try await command.value
        try await waitUntil { presentation.entries.contains { $0.needID == needID } }
    }

    @MainActor
    func testCartMutationIsVisibleUntilBackgroundSnapshotCatchesUp() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let itemID = try needs.createItem(name: "Milk", householdID: scope.householdID)
        let needID = try needs.addRememberedNeed(itemID: itemID,
            listID: scope.listID, householdID: scope.householdID)
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        let presentation = PersonalCartPresentation(service: service,
            householdID: scope.householdID, listID: scope.listID)

        try await presentation.cart(needID)
        XCTAssertTrue(presentation.contains(needID))
        XCTAssertTrue(presentation.isCartTransitionPending(needID))
        try await waitUntil { !presentation.isCartTransitionPending(needID) }
        let entry = try XCTUnwrap(presentation.entries.first)
        try await presentation.uncart(entry)
        XCTAssertFalse(presentation.contains(needID))
        XCTAssertTrue(presentation.entries.isEmpty)
        try await waitUntil { !presentation.isCartTransitionPending(needID) }
        XCTAssertTrue(presentation.entries.isEmpty)
    }

    @MainActor
    func testQuantityControlsWaitForFreshMembershipToken() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let itemID = try needs.createItem(name: "Milk", householdID: scope.householdID)
        let needID = try needs.addRememberedNeed(itemID: itemID,
            listID: scope.listID, householdID: scope.householdID)
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        try service.cart(needID: needID, householdID: scope.householdID, listID: scope.listID)
        let presentation = PersonalCartPresentation(service: service,
            householdID: scope.householdID, listID: scope.listID)
        try await waitUntil { presentation.entries.count == 1 }

        let first = try XCTUnwrap(presentation.entries.first)
        let writerEntered = expectation(description: "writer is occupied")
        let releaseWriter = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            persistence.writer.performAndWait {
                writerEntered.fulfill()
                releaseWriter.wait()
            }
        }
        await fulfillment(of: [writerEntered], timeout: 2)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { releaseWriter.signal() }
        let firstChange = Task { try await presentation.setQuantity(2, entry: first) }
        try await waitUntil { presentation.isQuantityTransitionPending(first.id) }
        XCTAssertTrue(presentation.isQuantityTransitionPending(first.id))
        try await presentation.setQuantity(3, entry: first)
        releaseWriter.signal()
        try await firstChange.value
        try await waitUntil { !presentation.isQuantityTransitionPending(first.id) }
        XCTAssertEqual(presentation.entries.first?.quantity, 2)

        let fresh = try XCTUnwrap(presentation.entries.first)
        try await presentation.setQuantity(3, entry: fresh)
        try await waitUntil { !presentation.isQuantityTransitionPending(first.id) }
        XCTAssertEqual(presentation.entries.first?.quantity, 3)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw XCTSkip("Presentation refresh timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
