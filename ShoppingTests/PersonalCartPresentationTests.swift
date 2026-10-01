import CoreData
import XCTest
@testable import Shopping

final class PersonalCartPresentationTests: XCTestCase {
    private struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    @MainActor
    func testLegacyReviewOnlyPublishesPendingEntriesAndDisappearsAfterDecision() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let item = try needs.createItem(name: "Milk", householdID: scope.householdID)
        let need = try needs.addRememberedNeed(itemID: item, listID: scope.listID, householdID: scope.householdID)
        try needs.setNeedCarted(needID: need, householdID: scope.householdID, listID: scope.listID, carted: true)
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        try service.captureLegacyReview()
        let presentation = PersonalCartPresentation(service: service, householdID: scope.householdID, listID: scope.listID)
        try await waitUntil { presentation.pendingLegacyReview.count == 1 }
        XCTAssertTrue(presentation.entries.isEmpty, "Legacy flags never claim personal ownership")
        let pending = try XCTUnwrap(presentation.pendingLegacyReview.first)
        try service.decideLegacyReview(id: pending.id, claim: false)
        presentation.refresh()
        try await waitUntil { presentation.pendingLegacyReview.isEmpty }
        XCTAssertEqual(try service.legacyReview().count, 1, "The audit record remains saved")
        XCTAssertTrue(try service.pendingLegacyReview(householdID: scope.householdID, listID: scope.listID).isEmpty)
    }

    @MainActor
    func testIncompleteLegacyReviewCannotBlockCheckoutOrPrivateCleanup() async throws {
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
        for need in [milk, bread] { try service.cart(needID: need, householdID: scope.householdID, listID: scope.listID) }
        let incoming = persistence.simulationContext()
        try incoming.performAndWait {
            let incomplete = LegacyCartReview(context: incoming)
            incomplete.id = UUID()
            incomplete.payload = nil
            incomplete.decision = "keep"
            incomplete.claimedAccount = ""
            try incoming.save()
        }
        let presentation = PersonalCartPresentation(service: service, householdID: scope.householdID, listID: scope.listID)
        try await waitUntil { presentation.recovery != nil }
        XCTAssertNotNil(presentation.recovery?.legacyReviewError)
        XCTAssertNil(presentation.error)
        XCTAssertEqual(Set(presentation.outstandingNeedIDs), [milk, bread])
        let entry = try XCTUnwrap(presentation.entries.first { $0.needID == milk })
        let checkout = try service.prepareCheckout(tokens: [entry.token])
        _ = try service.checkout(checkout, operationID: checkout.id)
        presentation.refresh()
        try await waitUntil { presentation.history.count == 1 }
        XCTAssertNil(presentation.error)
        try await presentation.uncart(XCTUnwrap(presentation.entries.first { $0.needID == bread }))
        try await waitUntil { presentation.entries.isEmpty }
    }

    @MainActor
    func testEarlierHistoryRemainsDiscoverableAfterFinalLegacyDecision() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let other = try needs.createHousehold(name: "Other home")
        let ice = try needs.addOneTimeNeed(title: "Ice", listID: scope.listID)
        try needs.setCarted(true, needID: ice)
        let clear = try needs.captureCarted(householdID: scope.householdID, listID: scope.listID)
        _ = try needs.clearCarted(using: clear)
        let milk = try needs.addOneTimeNeed(title: "Milk", listID: scope.listID)
        try needs.setCarted(true, needID: milk)
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        try service.captureLegacyReview()
        let pending = try XCTUnwrap(service.pendingLegacyReview(householdID: scope.householdID, listID: scope.listID).first)
        try service.decideLegacyReview(id: pending.id, claim: false)
        let snapshot = try service.recoverySnapshot(householdID: scope.householdID, listID: scope.listID)
        XCTAssertTrue(snapshot.pendingLegacyReview.isEmpty)
        XCTAssertTrue(snapshot.hasEarlierClearedGroceries)
        XCTAssertFalse(try service.recoverySnapshot(householdID: other.householdID, listID: other.listID).hasEarlierClearedGroceries)
        let presentation = PersonalCartPresentation(service: service, householdID: scope.householdID, listID: scope.listID)
        try await waitUntil { presentation.recovery != nil }
        XCTAssertTrue(presentation.canReviewEarlierCleared(in: .init(householdID: scope.householdID, listID: scope.listID)))
        XCTAssertFalse(presentation.canReviewEarlierCleared(in: .init(householdID: other.householdID, listID: other.listID)))
        XCTAssertFalse(presentation.canReviewEarlierCleared(in: .init(householdID: scope.householdID, listID: other.listID)))
        XCTAssertFalse(presentation.canReviewEarlierCleared(in: .init(householdID: nil, listID: nil)))
    }

    func testEarlierHistoryInSecondaryStoreIsDiscoverable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lifetime = SQLiteTestFixtureLifetime()
        addTeardownBlock { try lifetime.cleanup(); try FileManager.default.removeItem(at: directory) }
        let persistence = try lifetime.own(PersistenceController(storeURL: directory.appendingPathComponent("Private.sqlite"),
            additionalStoreURLs: [directory.appendingPathComponent("Shared.sqlite")]))
        let primary = try XCTUnwrap(persistence.primaryStore)
        let secondary = try XCTUnwrap(persistence.container.persistentStoreCoordinator.persistentStores.first { $0 != primary })
        let homeID = UUID(), listID = UUID()
        let incoming = lifetime.own(persistence.simulationContext())
        try incoming.performAndWait {
            let home = Household(context: incoming)
            incoming.assign(home, to: secondary)
            home.id = homeID; home.name = "Contributor home"
            let list = GroceryList(context: incoming)
            incoming.assign(list, to: secondary)
            list.id = listID; list.household = home
            let operation = ClearOperation(context: incoming)
            incoming.assign(operation, to: secondary)
            operation.id = UUID(); operation.createdAt = Date(); operation.household = home; operation.list = list
            try incoming.save()
        }
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        let snapshot = try service.recoverySnapshot(householdID: homeID, listID: listID)
        XCTAssertTrue(snapshot.hasEarlierClearedGroceries)
        XCTAssertTrue(snapshot.pendingLegacyReview.isEmpty)
    }

    @MainActor
    func testOtherHomeSavedCartRemainsDiscoverableAfterItsHouseholdDisappears() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let current = try needs.createHousehold()
        let other = try needs.createHousehold(name: "Other home")
        let milk = try needs.addOneTimeNeed(title: "Milk", listID: other.listID)
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        try service.cart(needID: milk, householdID: other.householdID, listID: other.listID)
        let incoming = persistence.simulationContext()
        try incoming.performAndWait {
            let request = Household.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", other.householdID as CVarArg)
            incoming.delete(try XCTUnwrap(incoming.fetch(request).first))
            try incoming.save()
        }
        let retained = PersonalCartScopeSnapshot(householdID: other.householdID, listID: other.listID)
        XCTAssertEqual(try service.recoverySnapshot(householdID: current.householdID, listID: current.listID).otherSavedScopes, [retained])
        let entry = try XCTUnwrap(service.entries(householdID: other.householdID, listID: other.listID).first)
        try service.uncart(entry.token)
        XCTAssertTrue(try service.recoverySnapshot(householdID: current.householdID, listID: current.listID).otherSavedScopes.isEmpty)
        XCTAssertTrue(try service.retainedScopes().contains(retained), "Audit-only scopes do not generate empty links")
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
