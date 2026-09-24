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

    func testPerformanceFixturesHaveStableRepresentativeCounts() throws {
        for (fixtureCase, itemCount) in [(ShoppingPreviewCase.performance, 500), (.stress, 1_000)] {
            let fixture = try ShoppingPreviewFixtures.make(fixtureCase)
            XCTAssertEqual(fixture.ids.itemIDs.count, itemCount)
            XCTAssertEqual(try fixture.service.allActiveNeedIDs(householdID: fixture.ids.householdID).count, itemCount)
            XCTAssertEqual(fixture.ids.storeIDs.count, 20)
            XCTAssertEqual(fixture.ids.categoryIDs.count, 100)
        }
    }

    func testArchivedCatalogFixturePreservesActiveNeedAndRulesWithoutChangingAnotherStore() throws {
        let archived = try ShoppingPreviewFixtures.make(.archivedCatalogItem)
        let populated = try ShoppingPreviewFixtures.make(.populated)
        XCTAssertNotEqual(archived.ids.householdID, populated.ids.householdID)
        XCTAssertTrue(Set(archived.ids.itemIDs.values).isDisjoint(with: populated.ids.itemIDs.values))
        XCTAssertTrue(Set(archived.ids.needIDs.values).isDisjoint(with: populated.ids.needIDs.values))
        for (fixture, isArchived) in [(archived, true), (populated, false)] {
            let granolaID = try XCTUnwrap(fixture.ids.itemIDs["granola"])
            let needID = try XCTUnwrap(fixture.ids.needIDs["granola"])
            XCTAssertTrue(try fixture.service.allActiveNeedIDs(householdID: fixture.ids.householdID).contains(needID))
            XCTAssertEqual(
                try fixture.service.storeEligibility(itemID: granolaID),
                .activeStores([try XCTUnwrap(fixture.ids.storeIDs["costco"])])
            )
            let context = fixture.persistence.simulationContext()
            try context.performAndWait {
                let current = try need(needID, in: context)
                let item = try XCTUnwrap(current.item)
                XCTAssertEqual(item.id, granolaID)
                XCTAssertEqual(item.isArchived, isArchived)
                XCTAssertEqual(item.category?.id, fixture.ids.categoryIDs["pantry"])
                XCTAssertEqual(item.name, "Granola")
                XCTAssertEqual(item.notes, "")
                XCTAssertFalse(current.archived)
                XCTAssertFalse(current.carted)
                XCTAssertEqual(current.notes, "Low sugar")
                XCTAssertEqual(current.urgency, NeedUrgency.urgent.rawValue)
                XCTAssertNil(current.quantity)
            }
        }
    }

    func testPromotionFixturesPreserveDistinctOccurrenceAndCatalogStateAfterReopen() throws {
        var occurrenceIDs = Set<UUID>()
        for fixtureCase in [ShoppingPreviewCase.promotionLinkExisting, .promotionConflict] {
            let url = temporaryURL("promotion.sqlite")
            let ids: ShoppingPreviewIDs
            do {
                let fixture = try ShoppingPreviewFixtures.make(fixtureCase, storeURL: url)
                ids = fixture.ids
            }
            let reopened = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: reopened)
            let oneTimeID = try XCTUnwrap(ids.needIDs["oneTime"])
            XCTAssertTrue(occurrenceIDs.insert(oneTimeID).inserted)
            let granolaID = try XCTUnwrap(ids.itemIDs["granola"])
            XCTAssertNotEqual(oneTimeID, granolaID)
            XCTAssertEqual(try service.allCatalogItemIDs(householdID: ids.householdID), [granolaID])
            XCTAssertEqual(
                try service.storeEligibility(itemID: granolaID),
                .activeStores([try XCTUnwrap(ids.storeIDs["costco"])])
            )
            let context = reopened.simulationContext()
            try context.performAndWait {
                let oneTime = try need(oneTimeID, in: context)
                XCTAssertEqual(oneTime.kind, NeedKind.oneTime.rawValue)
                XCTAssertNil(oneTime.item)
                XCTAssertEqual(oneTime.quantity, 2)
                XCTAssertEqual(oneTime.urgency, NeedUrgency.urgent.rawValue)
                XCTAssertEqual(oneTime.notes, "Buy this week")
                XCTAssertTrue(oneTime.oneTimeAnyStore)
                XCTAssertNil(oneTime.oneTimeCategory)
                XCTAssertTrue(oneTime.oneTimeStores?.isEmpty ?? true)
                XCTAssertFalse(oneTime.carted)
                XCTAssertFalse(oneTime.archived)
                XCTAssertEqual(oneTime.list?.id, ids.listID)
                let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first)
                XCTAssertEqual(item.name, "Granola")
                XCTAssertEqual(item.notes, "")
                XCTAssertEqual(item.category?.id, ids.categoryIDs["pantry"])
                if fixtureCase == .promotionConflict {
                    let remembered = try need(try XCTUnwrap(ids.needIDs["granola"]), in: context)
                    XCTAssertNotEqual(remembered.id, oneTimeID)
                    XCTAssertEqual(remembered.kind, NeedKind.remembered.rawValue)
                    XCTAssertEqual(remembered.item?.id, granolaID)
                    XCTAssertNil(remembered.quantity)
                    XCTAssertEqual(remembered.notes, "Low sugar")
                    XCTAssertEqual(remembered.urgency, NeedUrgency.urgent.rawValue)
                    XCTAssertFalse(remembered.carted)
                    XCTAssertFalse(remembered.archived)
                    XCTAssertEqual(oneTime.title, remembered.title)
                } else {
                    XCTAssertEqual(oneTime.title, "Breakfast cereal")
                    XCTAssertNil(ids.needIDs["granola"])
                }
            }
            XCTAssertEqual(
                try service.allActiveNeedIDs(householdID: ids.householdID).count,
                fixtureCase == .promotionConflict ? 2 : 1
            )
            XCTAssertEqual(try service.catalogSuggestionNames(householdID: ids.householdID), ["Granola"])
        }
    }

    func testInactiveSuggestionFixtureHasSavedDetailsWithoutCreatingACurrentNeed() throws {
        let fixture = try ShoppingPreviewFixtures.make(.inactiveCatalogSuggestion)
        XCTAssertTrue(try fixture.service.allActiveNeedIDs(householdID: fixture.ids.householdID).isEmpty)
        XCTAssertEqual(
            try fixture.service.catalogSuggestionNames(householdID: fixture.ids.householdID),
            ["Café au lait"]
        )
        let context = fixture.persistence.simulationContext()
        try context.performAndWait {
            let items = try context.fetch(Item.fetchRequest())
            XCTAssertEqual(items.count, 1)
            let item = try XCTUnwrap(items.first)
            XCTAssertEqual(item.id, fixture.ids.itemIDs["cafe"])
            XCTAssertEqual(item.notes, "Oat milk preferred")
            XCTAssertTrue(item.anyStore)
            XCTAssertNil(item.category)
            XCTAssertTrue(item.stores?.isEmpty ?? true)
        }
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

    @MainActor
    func testWritableAbsoluteUITestStorePathRemainsUnchanged() throws {
        let directory = temporaryURL("writable-store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestedURL = directory.appendingPathComponent("fixture.sqlite")

        let resolvedURL = try PersistenceBootstrap.uiTestStoreURL(
            for: requestedURL.path,
            applicationSupportDirectory: temporaryURL("unused-support")
        )

        XCTAssertEqual(resolvedURL, requestedURL)
    }

    @MainActor
    func testUnwritableUITestStorePathUsesAppSupportAndPrunesOldArtifacts() throws {
        let supportDirectory = temporaryURL("application-support")
        let storesDirectory = supportDirectory.appendingPathComponent("UITestStores", isDirectory: true)
        try FileManager.default.createDirectory(at: storesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        for index in 0..<14 {
            for suffix in ["", "-wal", "-shm"] {
                let url = storesDirectory.appendingPathComponent("fixture-\(index).sqlite\(suffix)")
                try Data().write(to: url)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                    ofItemAtPath: url.path
                )
            }
        }
        for index in 0..<30 {
            let url = storesDirectory.appendingPathComponent("history-\(index)")
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }

        let currentName = "current.sqlite"
        let resolvedURL = try PersistenceBootstrap.uiTestStoreURL(
            for: "/runner-sandbox/\(currentName)",
            applicationSupportDirectory: supportDirectory
        )
        try Data().write(to: resolvedURL)

        let remainingNames = Set(try FileManager.default.contentsOfDirectory(atPath: storesDirectory.path))
        XCTAssertEqual(remainingNames.filter { $0.hasSuffix(".sqlite") }.count, 12)
        XCTAssertTrue(remainingNames.contains(currentName))
        for index in 0..<3 {
            XCTAssertFalse(remainingNames.contains("fixture-\(index).sqlite"))
            XCTAssertFalse(remainingNames.contains("fixture-\(index).sqlite-wal"))
            XCTAssertFalse(remainingNames.contains("fixture-\(index).sqlite-shm"))
        }
        XCTAssertEqual(remainingNames.filter { $0.hasPrefix("history-") }.count, 24)
        for index in 0..<6 {
            XCTAssertFalse(remainingNames.contains("history-\(index)"))
        }
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
        let quantity: Int64?
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
