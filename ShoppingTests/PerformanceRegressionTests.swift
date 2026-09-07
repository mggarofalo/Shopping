import XCTest
@testable import Shopping

final class PerformanceRegressionTests: XCTestCase {
    private var fixture: ShoppingPreviewEnvironment!

    override func setUpWithError() throws {
        fixture = try ShoppingPreviewFixtures.make(.stress)
    }

    override func tearDown() {
        fixture = nil
    }

    func testStressFixtureProjectionLatency() throws {
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
                    categoryID: categoryID
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

    private func assertLatency(
        name: String,
        limit: TimeInterval,
        iterations: Int = 20,
        operation: () throws -> Void
    ) throws {
        try operation()
        var durations: [TimeInterval] = []
        for _ in 0..<iterations {
            let start = ProcessInfo.processInfo.systemUptime
            try operation()
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }
        durations.sort()
        let p50 = durations[durations.count / 2]
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
