import XCTest
@testable import Shopping

/// Screen projections at launch: reads must not queue behind the writer, and a burst of
/// store changes must not keep discarding finished reads (SHOPPING-263).
final class ProjectionLoadingTests: XCTestCase {
    @MainActor
    func testRequestsDuringASlowReadCollapseIntoOneFollowUpRead() async throws {
        let refresh = CoalescedRefresh()
        var started: [Int] = []
        var finished: [Int] = []
        var releaseFirstRead: CheckedContinuation<Void, Never>?
        refresh.request {
            started.append(1)
            await withCheckedContinuation { releaseFirstRead = $0 }
            finished.append(1)
        }
        try await waitForState("first read in progress") { releaseFirstRead != nil }
        for request in 2...5 {
            refresh.request {
                started.append(request)
                finished.append(request)
            }
        }
        releaseFirstRead?.resume()
        try await waitForState("follow-up read") { finished.count == 2 }
        XCTAssertEqual(started, [1, 5], "Requests made during a read collapse into the latest one")
        XCTAssertEqual(finished, [1, 5], "The first slow read still completes and can publish")
    }

    @MainActor
    func testContinuousChangesCannotStarveReads() async throws {
        let refresh = CoalescedRefresh()
        var finished = 0
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .milliseconds(600))
        // Changes arrive faster than one read takes, like merges during launch sync.
        while clock.now < end {
            refresh.request {
                try? await Task.sleep(for: .milliseconds(50))
                finished += 1
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(finished, 3, "Reads keep completing while changes continue")
    }

    func testScreenProjectionsDoNotWaitForABusyWriter() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let scope = try service.createHousehold()
        let itemID = try service.createItem(name: "Milk", householdID: scope.householdID)
        let needID = try service.addRememberedNeed(itemID: itemID, listID: scope.listID, householdID: scope.householdID)
        let entered = expectation(description: "writer occupied")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            persistence.writer.performAndWait {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        defer { release.signal() }

        let start = ContinuousClock.now
        let (groceries, catalog, membership) = try await Task.detached {
            let groceries = try service.groceryNeedProjection(
                householdID: scope.householdID, listID: scope.listID, filter: GroceryNeedFilter())
            let catalog = try service.filteredCatalogItemIDs(householdID: scope.householdID, filter: CatalogItemFilter())
            let membership = try service.catalogListMembership(
                itemIDs: [itemID], householdID: scope.householdID, listID: scope.listID)
            return (groceries.matchingNeedIDs, catalog, membership[itemID])
        }.value
        // The writer stays occupied for ten seconds; a read queued behind it would take that long.
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        XCTAssertEqual(groceries, [needID])
        XCTAssertEqual(catalog, [itemID])
        guard case .present(let presentNeedID, _) = membership else { return XCTFail("Missing membership") }
        XCTAssertEqual(presentNeedID, needID)
    }
}
