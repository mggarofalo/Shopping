import CoreData
import XCTest
@testable import Shopping

final class CatalogFilterTests: XCTestCase {
    func testIndependentPurchaseRuleMatrix() {
        let a = UUID(), b = UUID(), c = UUID()
        let active: Set<UUID> = [a, b, c]
        struct Case {
            let value: PurchaseRuleValue
            let selected: UUID?
            let include: Set<UUID>
            let exclude: Set<UUID>
            let expectedAvailability: PurchaseAvailability
            let expectedMatch: Bool
        }
        let cases = [
            Case(value: .init(explicitStoreIDs: [a], anyStore: false), selected: a, include: [], exclude: [], expectedAvailability: .mustBuyHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [a], anyStore: false), selected: b, include: [], exclude: [], expectedAvailability: .unavailable, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a, b], anyStore: false), selected: a, include: [], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [], anyStore: true), selected: c, include: [], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [a], anyStore: true), selected: b, include: [a], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [], anyStore: false), selected: nil, include: [], exclude: [], expectedAvailability: .needsStore, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [a, b], anyStore: false), selected: a, include: [b], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [a, b], anyStore: false), selected: a, include: [c], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a, b], anyStore: false), selected: a, include: [], exclude: [b], expectedAvailability: .flexibleHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a], anyStore: false), selected: a, include: [a], exclude: [a], expectedAvailability: .mustBuyHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [], anyStore: true), selected: a, include: [], exclude: [a], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [], anyStore: true), selected: a, include: [a], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a], anyStore: true), selected: b, include: [b], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a], anyStore: false), selected: b, include: [a], exclude: [], expectedAvailability: .unavailable, expectedMatch: false)
        ]
        for (index, testCase) in cases.enumerated() {
            let filter = PurchaseFilter(
                selectedStoreID: testCase.selected,
                includedStoreIDs: testCase.include,
                excludedStoreIDs: testCase.exclude
            )
            XCTAssertEqual(filter.matches(testCase.value, activeStoreIDs: active), testCase.expectedMatch, "case \(index)")
            XCTAssertEqual(
                filter.availability(of: testCase.value, selectedStoreID: testCase.selected, activeStoreIDs: active),
                testCase.expectedAvailability,
                "case \(index)"
            )
        }

        let archivedB: Set<UUID> = [a, c]
        let retained = PurchaseRuleValue(explicitStoreIDs: [a, b], anyStore: false)
        XCTAssertEqual(PurchaseFilter().availability(of: retained, selectedStoreID: a, activeStoreIDs: archivedB), .mustBuyHere)
        XCTAssertEqual(PurchaseFilter().availability(of: retained, selectedStoreID: b, activeStoreIDs: archivedB), .unavailable)
        XCTAssertEqual(PurchaseFilter().availability(of: .init(explicitStoreIDs: [b], anyStore: false), selectedStoreID: nil, activeStoreIDs: archivedB), .needsStore)
    }

    func testGenericRuleValueCoversOneTimeRulesWithoutCatalogIdentity() {
        let a = UUID(), b = UUID()
        let oneTime = PurchaseRuleValue(explicitStoreIDs: [a], anyStore: false)
        XCTAssertEqual(PurchaseFilter().availability(of: oneTime, selectedStoreID: a, activeStoreIDs: [a, b]), .mustBuyHere)
        XCTAssertFalse(PurchaseFilter(selectedStoreID: b).matches(oneTime, activeStoreIDs: [a, b]))
        XCTAssertEqual(PurchaseFilter().availability(of: .init(explicitStoreIDs: [], anyStore: false), selectedStoreID: nil, activeStoreIDs: [a, b]), .needsStore)
    }

    func testCatalogMetadataRoundTripsAndTagEditDoesNotChangeDemand() throws {
        let url = temporaryStoreURL()
        var householdID: UUID!, itemID: UUID!, needID: UUID!, costcoID: UUID!, publixID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            householdID = ids.householdID
            costcoID = try service.createStore(name: "Costco", householdID: householdID)
            publixID = try service.createStore(name: "Publix", householdID: householdID)
            let categoryID = try service.createCategory(name: "Frozen", householdID: householdID)
            itemID = try service.createItem(
                name: " Kirkland Strawberries 4 lb ",
                notes: " Best value ",
                categoryID: categoryID,
                storeIDs: [costcoID],
                householdID: householdID,
                anyStore: false
            )
            needID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
            try service.setQuantity(2, needID: needID)
            try service.setCarted(true, needID: needID)
            XCTAssertEqual(
                try service.filteredActiveNeedIDs(
                    householdID: householdID,
                    filter: GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: costcoID))
                ),
                [needID]
            )
            try service.updateItemMetadata(
                itemID: itemID,
                householdID: householdID,
                name: "Kirkland Organic Strawberries 4 lb",
                notes: "Best value",
                categoryID: categoryID,
                isArchived: false
            )
            XCTAssertEqual(
                try service.filteredActiveNeedIDs(householdID: householdID, filter: GroceryNeedFilter(text: "organic strawberries")),
                [needID]
            )
            XCTAssertEqual(
                try service.filteredActiveNeedIDs(householdID: householdID, filter: GroceryNeedFilter(text: "Kirkland Strawberries")),
                []
            )
            try service.setPurchaseRules(itemID: itemID, anyStore: false, storeIDs: [publixID])
            XCTAssertEqual(
                try service.filteredActiveNeedIDs(
                    householdID: householdID,
                    filter: GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: costcoID))
                ),
                []
            )
            XCTAssertEqual(
                try service.filteredActiveNeedIDs(
                    householdID: householdID,
                    filter: GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: publixID))
                ),
                [needID]
            )
        }

        let persistence = try PersistenceController(storeURL: url)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let item = try self.fetchItem(itemID, context: context)
            XCTAssertEqual(item.name, "Kirkland Organic Strawberries 4 lb")
            XCTAssertEqual(item.notes, "Best value")
            XCTAssertEqual(Set(item.stores?.map(\.id) ?? []), [publixID])
            let need = try self.fetchNeed(needID, context: context)
            XCTAssertEqual(need.quantity, 2)
            XCTAssertTrue(need.carted)
            XCTAssertEqual(need.item?.id, itemID)
        }
    }

    func testCatalogAndGroceryDatasetsAndSuggestionsRemainDistinct() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let storeID = try service.createStore(name: "Costco", householdID: ids.householdID)
        let activeItem = try service.createItem(name: "  Oatly   Full Fat  ", householdID: ids.householdID)
        let duplicate = try service.createItem(name: "oatly full fat", householdID: ids.householdID)
        let archivedItem = try service.createItem(
            name: "Hidden brand",
            storeIDs: [storeID],
            householdID: ids.householdID,
            anyStore: false
        )
        let rememberedNeed = try service.addRememberedNeed(itemID: archivedItem, listID: ids.listID)
        try service.updateItemMetadata(itemID: archivedItem, householdID: ids.householdID, name: "Hidden brand", notes: "", categoryID: nil, isArchived: true)
        XCTAssertEqual(try service.addRememberedNeed(itemID: archivedItem, listID: ids.listID), rememberedNeed)
        let oneTimeNeed = try service.addOneTimeNeed(title: "Party ice", listID: ids.listID)

        XCTAssertEqual(try service.catalogSuggestionNames(householdID: ids.householdID), ["Oatly Full Fat"])
        XCTAssertEqual(try service.allCatalogItemIDs(householdID: ids.householdID), [activeItem, duplicate])
        XCTAssertEqual(try service.allActiveNeedIDs(householdID: ids.householdID), [rememberedNeed, oneTimeNeed])
        XCTAssertEqual(
            try service.filteredActiveNeedIDs(
                householdID: ids.householdID,
                filter: GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: storeID))
            ),
            [rememberedNeed, oneTimeNeed].sorted { $0.uuidString < $1.uuidString }
        )
    }

    func testStaleArchivedCatalogIDCannotCreateNewDemand() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let itemID = try service.createItem(name: "Old favorite", householdID: ids.householdID)
        try service.updateItemMetadata(itemID: itemID, householdID: ids.householdID, name: "Old favorite", notes: "", categoryID: nil, isArchived: true)

        XCTAssertThrowsError(try service.addRememberedNeed(itemID: itemID, listID: ids.listID)) {
            XCTAssertEqual($0 as? NeedServiceError, .itemArchived)
        }
        XCTAssertTrue(try service.allActiveNeedIDs(householdID: ids.householdID).isEmpty)
    }

    func testAtomicCatalogCreationRejectsMissingActiveRuleAndForeignMetadata() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold()
        let foreign = try service.createHousehold()
        let archivedStore = try service.createStore(name: "Closed", householdID: local.householdID)
        try service.setStoreArchived(true, storeID: archivedStore, householdID: local.householdID)
        let foreignStore = try service.createStore(name: "Foreign", householdID: foreign.householdID)
        let foreignCategory = try service.createCategory(name: "Foreign", householdID: foreign.householdID)

        XCTAssertThrowsError(try service.createItem(name: " ", householdID: local.householdID))
        XCTAssertThrowsError(try service.createItem(name: "Rice", storeIDs: [], householdID: local.householdID, anyStore: false))
        XCTAssertThrowsError(try service.createItem(name: "Rice", storeIDs: [archivedStore], householdID: local.householdID, anyStore: false))
        XCTAssertThrowsError(try service.createItem(name: "Rice", storeIDs: [foreignStore], householdID: local.householdID, anyStore: false))
        XCTAssertThrowsError(try service.createItem(name: "Rice", categoryID: foreignCategory, householdID: local.householdID))
        XCTAssertEqual(try service.allCatalogItemIDs(householdID: local.householdID), [])
    }

    private func fetchItem(_ id: UUID, context: NSManagedObjectContext) throws -> Item {
        let request = Item.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func fetchNeed(_ id: UUID, context: NSManagedObjectContext) throws -> Need {
        let request = Need.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingCatalogTests-\(UUID().uuidString).sqlite")
    }
}
