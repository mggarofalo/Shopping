import CoreData
import XCTest
@testable import Shopping

final class PreviewFixtureTests: XCTestCase {
    func testPopulatedFixtureCoversPurchaseUrgencyLifecycleAndSuggestionMatrix() throws {
        let fixture = try ShoppingPreviewFixtures.make(.populated)
        let service = fixture.service
        let ids = fixture.ids
        let costco = try XCTUnwrap(ids.storeIDs["costco"])
        let publix = try XCTUnwrap(ids.storeIDs["publix"])
        let walmart = try XCTUnwrap(ids.storeIDs["walmart"])

        XCTAssertEqual(try service.storeEligibility(itemID: try XCTUnwrap(ids.itemIDs["bananas"])), .anyStore)
        XCTAssertEqual(try service.storeEligibility(itemID: try XCTUnwrap(ids.itemIDs["granola"])), .activeStores([costco]))
        XCTAssertEqual(try service.storeEligibility(itemID: try XCTUnwrap(ids.itemIDs["chipotles"])), .activeStores([publix]))
        XCTAssertEqual(Set(try activeStoreIDs(for: try XCTUnwrap(ids.itemIDs["rolls"]), in: fixture)), [costco, walmart])
        XCTAssertEqual(try service.storeEligibility(itemID: try XCTUnwrap(ids.itemIDs["needsStore"])), .needsStore)

        let excludedCostco = CatalogItemFilter(purchase: PurchaseFilter(excludedStoreIDs: [costco]))
        let excludedIDs = try service.filteredCatalogItemIDs(householdID: ids.householdID, filter: excludedCostco)
        XCTAssertFalse(excludedIDs.contains(try XCTUnwrap(ids.itemIDs["granola"])))
        XCTAssertFalse(excludedIDs.contains(try XCTUnwrap(ids.itemIDs["rolls"])))
        XCTAssertTrue(excludedIDs.contains(try XCTUnwrap(ids.itemIDs["chipotles"])))

        let context = fixture.persistence.simulationContext()
        let needs = try fetchNeedSnapshots(in: context)
        XCTAssertTrue(try XCTUnwrap(needs[ids.needIDs["strawberries"]!]).carted)
        XCTAssertEqual(try XCTUnwrap(needs[ids.needIDs["granola"]!]).urgency, NeedUrgency.urgent.rawValue)
        let oneTime = try XCTUnwrap(needs[ids.needIDs["oneTime"]!])
        XCTAssertEqual(oneTime.kind, NeedKind.oneTime.rawValue)
        XCTAssertFalse(oneTime.hasItem)
        let cleared = try XCTUnwrap(needs[ids.needIDs["recentlyCleared"]!])
        XCTAssertTrue(cleared.archived)
        XCTAssertEqual(cleared.clearOperationID, ids.clearOperationID)
        XCTAssertFalse(try service.catalogSuggestionNames(householdID: ids.householdID).contains(oneTime.title))
    }

    func testEveryFixtureCaseBuildsInAnIsolatedStore() throws {
        for fixtureCase in ShoppingPreviewCase.allCases {
            let fixture = try ShoppingPreviewFixtures.make(fixtureCase)
            XCTAssertEqual(try fixture.service.firstHouseholdSelection()?.householdID, fixture.ids.householdID)
        }
        let empty = try ShoppingPreviewFixtures.make(.empty)
        XCTAssertTrue(try empty.service.allCatalogItemIDs(householdID: empty.ids.householdID).isEmpty)
        XCTAssertTrue(try empty.service.allActiveNeedIDs(householdID: empty.ids.householdID).isEmpty)

        let archived = try ShoppingPreviewFixtures.make(.archivedStore)
        XCTAssertEqual(
            try archived.service.storeEligibility(itemID: try XCTUnwrap(archived.ids.itemIDs["granola"])),
            .needsStore
        )

        let largeText = try ShoppingPreviewFixtures.make(.largeText)
        let largeSnapshots = try fetchNeedSnapshots(in: largeText.persistence.simulationContext())
        XCTAssertGreaterThan(try XCTUnwrap(largeSnapshots[largeText.ids.needIDs["oneTime"]!]).notes.count, 500)

        let pending = try ShoppingPreviewFixtures.make(.pendingRelationship)
        let pendingSnapshots = try fetchNeedSnapshots(in: pending.persistence.simulationContext())
        XCTAssertTrue(pendingSnapshots.values.contains { $0.kind == NeedKind.remembered.rawValue && !$0.hasItem })
    }

    func testDiskBackedFixtureRetainsRecoveryAndOneTimeDoesNotPolluteCatalogAfterReopen() throws {
        let url = temporaryURL("fixture.sqlite")
        var ids: ShoppingPreviewIDs!
        do {
            let fixture = try ShoppingPreviewFixtures.make(.populated, storeURL: url)
            ids = fixture.ids
        }
        XCTAssertThrowsError(try ShoppingPreviewFixtures.make(.empty, storeURL: url)) {
            XCTAssertEqual($0 as? ShoppingPreviewFixtureError, .storeAlreadyExists)
        }
        let reopened = try PersistenceController(storeURL: url)
        let service = NeedService(persistence: reopened)
        XCTAssertEqual(try service.firstHouseholdSelection()?.householdID, ids.householdID)
        XCTAssertEqual(try service.undoClear(operationID: try XCTUnwrap(ids.clearOperationID)), 1)
        XCTAssertFalse(try service.catalogSuggestionNames(householdID: ids.householdID).contains("Party ice"))
        XCTAssertFalse(try service.catalogSuggestionNames(householdID: ids.householdID).contains("Birthday candles"))
        XCTAssertEqual(try service.allCatalogItemIDs(householdID: ids.householdID).count, 6)
    }

    func testTwoContextHarnessKeepsStaleSnapshotsAndAppliesExplicitSaveOrder() throws {
        for order in [LocalTwoContextHarness.SaveOrder.firstThenSecond, .secondThenFirst] {
            let harness = try LocalTwoContextHarness(storeURL: temporaryURL("harness.sqlite"))
            let service = NeedService(persistence: harness.persistence)
            let selection = try service.createHousehold()
            let needID = try service.addOneTimeNeed(title: "Offline ice", listID: selection.listID)
            try load(needID, in: harness.first)
            try load(needID, in: harness.second)
            try harness.stage(.first) { try self.need(needID, in: $0).quantity = 4 }
            try harness.stage(.second) { try self.need(needID, in: $0).notes = "Second replica note" }
            try harness.save(in: order)

            let result = try needSnapshot(needID, in: harness.persistence.simulationContext())
            XCTAssertEqual(result.quantity, 4)
            XCTAssertEqual(result.notes, "Second replica note")
        }
    }

    private func activeStoreIDs(for itemID: UUID, in fixture: ShoppingPreviewEnvironment) throws -> [UUID] {
        let context = fixture.persistence.simulationContext()
        return try context.performAndWait {
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            return try XCTUnwrap(context.fetch(request).first).stores?.filter { !$0.isArchived }.map(\.id) ?? []
        }
    }

    private struct NeedSnapshot {
        let title: String
        let quantity: Int64
        let notes: String
        let carted: Bool
        let urgency: String
        let kind: String
        let hasItem: Bool
        let archived: Bool
        let clearOperationID: UUID?
    }

    private func fetchNeedSnapshots(in context: NSManagedObjectContext) throws -> [UUID: NeedSnapshot] {
        try context.performAndWait {
            Dictionary(uniqueKeysWithValues: try context.fetch(Need.fetchRequest()).map {
                ($0.id, snapshot($0))
            })
        }
    }

    private func needSnapshot(_ id: UUID, in context: NSManagedObjectContext) throws -> NeedSnapshot {
        try context.performAndWait { snapshot(try need(id, in: context)) }
    }

    private func snapshot(_ need: Need) -> NeedSnapshot {
        NeedSnapshot(
            title: need.title,
            quantity: need.quantity,
            notes: need.notes,
            carted: need.carted,
            urgency: need.urgency,
            kind: need.kind,
            hasItem: need.item != nil,
            archived: need.archived,
            clearOperationID: need.clearOperationID
        )
    }

    private func load(_ id: UUID, in context: NSManagedObjectContext) throws {
        try context.performAndWait { _ = try need(id, in: context) }
    }

    private func need(_ id: UUID, in context: NSManagedObjectContext) throws -> Need {
        let request = Need.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingPreviewTests-\(UUID().uuidString)-\(name)")
    }
}
