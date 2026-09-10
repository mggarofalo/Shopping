import XCTest
@testable import Shopping

final class PerformanceRegressionTests: XCTestCase {
    private final class MeasurementBox: @unchecked Sendable {
        let operation: () throws -> Void
        var result: Result<[TimeInterval], Error>?

        init(operation: @escaping () throws -> Void) {
            self.operation = operation
        }
    }

    private var fixture: ShoppingPreviewEnvironment!

    override func setUpWithError() throws {
        fixture = try ShoppingPreviewFixtures.make(.stress)
    }

    override func tearDown() {
        fixture = nil
    }

    func testStressFixtureProjectionLatency() throws {
        waitForTraceAttachmentIfRequested()
        let service = fixture.service
        let ids = fixture.ids
        let storeID = try XCTUnwrap(ids.storeIDs["store-3"])
        let categoryID = try XCTUnwrap(ids.categoryIDs["category-12"])

        try assertLatency(name: "catalog.all", limit: 0.100) {
            _ = try service.filteredCatalogItemIDs(householdID: ids.householdID, filter: CatalogItemFilter())
        }
        try assertLatency(name: "catalog.filtered", limit: 0.100) {
            _ = try service.filteredCatalogItemIDs(
                householdID: ids.householdID,
                filter: CatalogItemFilter(
                    purchase: PurchaseFilter(selectedStoreID: storeID),
                    text: "item 09",
                    categoryIDs: [categoryID]
                )
            )
        }
        try assertLatency(name: "groceries.all", limit: 0.100) {
            _ = try service.filteredActiveNeedIDs(householdID: ids.householdID, filter: GroceryNeedFilter())
        }
        try assertLatency(name: "groceries.filtered", limit: 0.100) {
            _ = try service.filteredActiveNeedIDs(
                householdID: ids.householdID,
                filter: GroceryNeedFilter(
                    purchase: PurchaseFilter(selectedStoreID: storeID),
                    text: "item 01",
                    categoryID: categoryID,
                    urgency: NeedUrgency.normal.rawValue
                )
            )
        }
    }

    private func waitForTraceAttachmentIfRequested() {
        guard let rawDelay = ProcessInfo.processInfo.environment["SHOPPING_PERFORMANCE_TRACE_DELAY"],
              let delay = TimeInterval(rawDelay), delay > 0 else { return }
        let ready = expectation(description: "Wait for an external trace attachment")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            ready.fulfill()
        }
        wait(for: [ready], timeout: delay + 1)
    }

    func testStressFixtureBatchPreviewLatency() throws {
        let service = fixture.service
        let ids = fixture.ids
        let selectedIDs = Set(ids.itemIDs.values)
        try assertLatency(name: "catalog.batch-preview", limit: 0.150, iterations: 10) {
            _ = try service.captureManagementBatch(
                entity: .catalogItem,
                action: .delete,
                ids: selectedIDs,
                householdID: ids.householdID,
                listID: ids.listID
            )
        }
    }

    func testCatalogSuggestionMatcherLatency() throws {
        let candidates = (0..<1_000).map { index in
            CatalogSuggestionCandidate(
                id: UUID(uuidString: String(
                    format: "00000000-0000-0000-0000-%012d", index + 1
                ))!,
                name: String(format: "Catalog item %04d", index + 1)
            )
        }
        let expectedID = candidates[998].id
        XCTAssertEqual(
            CatalogSuggestionMatcher.suggestions(
                for: "Catalog item 0999", candidates: candidates
            ).first?.candidate.id,
            expectedID
        )
        try assertLatency(name: "catalog.suggestions", limit: 0.100) {
            _ = CatalogSuggestionMatcher.suggestions(
                for: "Catalog item 0999", candidates: candidates
            )
        }
    }

    private func assertLatency(
        name: String,
        limit: TimeInterval,
        iterations: Int = 20,
        operation: @escaping () throws -> Void
    ) throws {
        let finished = expectation(description: "Measure \(name) off the main thread")
        let measurement = MeasurementBox(operation: operation)
        DispatchQueue.global(qos: .userInitiated).async {
            measurement.result = Result {
                try measurement.operation()
                var durations: [TimeInterval] = []
                for _ in 0..<iterations {
                    let start = ProcessInfo.processInfo.systemUptime
                    try measurement.operation()
                    durations.append(ProcessInfo.processInfo.systemUptime - start)
                }
                return durations
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        var durations = try XCTUnwrap(measurement.result).get()
        durations.sort()
        let p50Index = min(durations.count - 1, max(0, Int(ceil(Double(durations.count) * 0.50)) - 1))
        let p50 = durations[p50Index]
        let p95Index = min(durations.count - 1, max(0, Int(ceil(Double(durations.count) * 0.95)) - 1))
        let p95 = durations[p95Index]
        let worst = try XCTUnwrap(durations.last)
        print(String(
            format: "SHOPPING_PERF %@ p50=%.3fms p95=%.3fms worst=%.3fms iterations=%d",
            name, p50 * 1_000, p95 * 1_000, worst * 1_000, iterations
        ))
        XCTAssertLessThan(worst, limit, "\(name) exceeded the \(Int(limit * 1_000)) ms regression limit")
    }
}
