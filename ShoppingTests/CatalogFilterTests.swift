import CoreData
import XCTest
@testable import Shopping

final class CatalogFilterTests: XCTestCase {
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

    func testAtomicCatalogCreationDefaultsToAnyStoreAndRejectsInvalidMetadata() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold()
        let foreign = try service.createHousehold()
        let archivedStore = try service.createStore(name: "Closed", householdID: local.householdID)
        try service.setStoreArchived(true, storeID: archivedStore, householdID: local.householdID)
        let foreignStore = try service.createStore(name: "Foreign", householdID: foreign.householdID)
        let foreignCategory = try service.createCategory(name: "Foreign", householdID: foreign.householdID)

        XCTAssertThrowsError(try service.createItem(name: " ", householdID: local.householdID))
        let untagged = try service.createItem(name: "Rice", storeIDs: [], householdID: local.householdID, anyStore: false)
        XCTAssertEqual(try service.storeEligibility(itemID: untagged), .anyStore)
        XCTAssertThrowsError(try service.createItem(name: "Rice", storeIDs: [archivedStore], householdID: local.householdID, anyStore: false))
        XCTAssertThrowsError(try service.createItem(name: "Rice", storeIDs: [foreignStore], householdID: local.householdID, anyStore: false))
        XCTAssertThrowsError(try service.createItem(name: "Rice", categoryID: foreignCategory, householdID: local.householdID))
        XCTAssertEqual(try service.allCatalogItemIDs(householdID: local.householdID), [untagged])
    }

    func testUntaggedRulesSurviveRelaunchAndNeverInventLiteralTagsOrOrphanEligibility() throws {
        let url = temporaryStoreURL()
        let persistence = try PersistenceController(storeURL: url)
        let service = NeedService(persistence: persistence)
        let scope = try service.createHousehold()
        let store = try service.createStore(name: "Market", householdID: scope.householdID)
        let item = try service.createItem(name: "Rice", householdID: scope.householdID)
        let remembered = try service.addRememberedNeed(itemID: item, listID: scope.listID)
        let oneTime = try service.addOneTimeNeed(title: "Basil", anyStore: false, listID: scope.listID)
        let orphanItem = try service.createItem(name: "Pending", householdID: scope.householdID)
        let orphan = try service.addRememberedNeed(itemID: orphanItem, listID: scope.listID)
        for need in [remembered, oneTime, orphan] {
            try service.setCarted(true, needID: need)
        }
        let unresolvedItem = try service.createItem(name: "Unresolved", householdID: scope.householdID)
        let unresolved = try service.addRememberedNeed(itemID: unresolvedItem, listID: scope.listID)
        let context = persistence.simulationContext()
        try context.performAndWait {
            // Legacy/imported rows can have false plus an empty tag relationship.
            try fetchItem(item, context: context).anyStore = false
            try fetchNeed(orphan, context: context).item = nil
            let unresolvedObject = try fetchItem(unresolvedItem, context: context)
            unresolvedObject.id = PersistenceModel.unsetID
            unresolvedObject.anyStore = false
            try context.save()
        }
        let relaunched = try PersistenceController(storeURL: url)
        let reloaded = NeedService(persistence: relaunched)
        let selected = GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: store))
        XCTAssertEqual(Set(try reloaded.filteredActiveNeedIDs(householdID: scope.householdID, filter: selected)), [remembered, oneTime])
        XCTAssertTrue(try reloaded.filteredActiveNeedIDs(householdID: scope.householdID, filter: GroceryNeedFilter()).contains(orphan))
        XCTAssertTrue(try reloaded.filteredActiveNeedIDs(householdID: scope.householdID, filter: GroceryNeedFilter()).contains(unresolved))
        XCTAssertTrue(try reloaded.filteredActiveNeedIDs(householdID: scope.householdID, filter: GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: store, includedStoreIDs: [store]))).isEmpty)
        XCTAssertEqual(try reloaded.storeEligibility(itemID: item), .anyStore)
        let preview = try reloaded.prepareClearCarted(householdID: scope.householdID, listID: scope.listID, filter: selected)
        XCTAssertEqual(Set(preview.rows.map(\.needID)), [remembered, oneTime])
        let allPreview = try reloaded.prepareClearCarted(householdID: scope.householdID, listID: scope.listID, filter: GroceryNeedFilter())
        XCTAssertEqual(Set(allPreview.rows.map(\.needID)), [remembered, oneTime, orphan])
        try reloaded.setPurchaseRules(itemID: item, anyStore: false, storeIDs: [store])
        XCTAssertEqual(try reloaded.storeEligibility(itemID: item), .activeStores([store]))
        try reloaded.setPurchaseRules(itemID: item, anyStore: false, storeIDs: [])
        XCTAssertEqual(try reloaded.storeEligibility(itemID: item), .anyStore)
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
