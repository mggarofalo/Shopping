import CoreData
import XCTest
@testable import Shopping

final class CategoryManagementTests: XCTestCase {
    func testRenameAndExactReorderAreAtomicAndHouseholdScoped() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold()
        let foreign = try service.createHousehold()
        let produce = try service.createCategory(name: "Produce", householdID: local.householdID)
        let bakery = try service.createCategory(name: "Bakery", householdID: local.householdID)
        let foreignCategory = try service.createCategory(name: "Foreign", householdID: foreign.householdID)

        try service.renameCategory(name: "  Fresh produce  ", categoryID: produce, householdID: local.householdID)
        try service.reorderCategories([bakery, produce], householdID: local.householdID)
        XCTAssertEqual(try categoryStates(local.householdID, persistence: persistence).map(\.name), ["Bakery", "Fresh produce"])

        XCTAssertThrowsError(try service.renameCategory(name: " ", categoryID: produce, householdID: local.householdID)) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidName)
        }
        XCTAssertThrowsError(try service.renameCategory(name: "Wrong", categoryID: produce, householdID: foreign.householdID)) {
            XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
        }
        for invalid in [[produce], [bakery, bakery], [bakery, foreignCategory], [bakery, PersistenceModel.unsetID]] {
            XCTAssertThrowsError(try service.reorderCategories(invalid, householdID: local.householdID)) {
                XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
            }
            XCTAssertEqual(try categoryStates(local.householdID, persistence: persistence).map(\.id), [bakery, produce])
        }
        XCTAssertEqual(try categoryName(produce, persistence: persistence), "Fresh produce")
    }

    func testReorderRejectsImportedDuplicateAndZeroCategoryIdentitiesWithoutMutation() throws {
        for badID in [PersistenceModel.unsetID, UUID()] {
            let persistence = try makePersistence()
            let service = NeedService(persistence: persistence)
            let selection = try service.createHousehold()
            let valid = try service.createCategory(name: "Valid", householdID: selection.householdID, displayOrder: 7)
            try insertCategory(id: badID, name: "Imported A", order: 8, householdID: selection.householdID, persistence: persistence)
            if badID != PersistenceModel.unsetID {
                try insertCategory(id: badID, name: "Imported B", order: 9, householdID: selection.householdID, persistence: persistence)
            }
            let before = try categoryStates(selection.householdID, persistence: persistence)
            let requested = badID == PersistenceModel.unsetID ? [valid, badID] : [valid, badID, badID]
            XCTAssertThrowsError(try service.reorderCategories(requested, householdID: selection.householdID)) {
                XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
            }
            XCTAssertEqual(try categoryStates(selection.householdID, persistence: persistence), before)
        }
    }

    func testRemoveNullifiesCatalogAndOneTimeCategoriesWithoutDeletingData() throws {
        let url = temporaryStoreURL()
        var householdID: UUID!, categoryID: UUID!, itemID: UUID!, rememberedID: UUID!, oneTimeID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: persistence)
            let selection = try service.createHousehold()
            householdID = selection.householdID
            categoryID = try service.createCategory(name: "Frozen", householdID: householdID)
            itemID = try service.createItem(name: "Peas", categoryID: categoryID, householdID: householdID)
            rememberedID = try service.addRememberedNeed(itemID: itemID, listID: selection.listID)
            oneTimeID = try service.addOneTimeNeed(title: "Ice", categoryID: categoryID, listID: selection.listID)
            try service.removeCategory(categoryID: categoryID, householdID: householdID)
        }

        let reopened = try PersistenceController(storeURL: url)
        let context = reopened.simulationContext()
        try context.performAndWait {
            XCTAssertNil(try fetch(Item.self, entity: "Item", id: itemID, in: context).category)
            XCTAssertNil(try fetch(Need.self, entity: "Need", id: oneTimeID, in: context).oneTimeCategory)
            let needIDs = Set(try context.fetch(Need.fetchRequest()).filter { !$0.archived }.map(\.id))
            XCTAssertEqual(needIDs, [rememberedID, oneTimeID])
            XCTAssertEqual(try context.fetch(Item.fetchRequest()).map(\.id), [itemID])
            XCTAssertTrue(try context.fetch(Shopping.Category.fetchRequest()).isEmpty)
        }
    }

    func testRemoveCategoryAdvancesActiveOneTimeRevisionSoEarlierClearSkipsIt() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let categoryID = try service.createCategory(name: "Party", householdID: selection.householdID)
        let needID = try service.addOneTimeNeed(title: "Ice", categoryID: categoryID, listID: selection.listID)
        try service.setCarted(true, needID: needID)
        let token = try service.captureCarted(householdID: selection.householdID, listID: selection.listID)

        try service.removeCategory(categoryID: categoryID, householdID: selection.householdID)
        XCTAssertEqual(try service.clearCarted(using: token), 0)

        let context = persistence.simulationContext()
        try context.performAndWait {
            let need = try fetch(Need.self, entity: "Need", id: needID, in: context)
            XCTAssertFalse(need.archived)
            XCTAssertTrue(need.carted)
            XCTAssertNil(need.oneTimeCategory)
            XCTAssertNil(need.clearOperationID)
        }
    }

    func testRemoveCategoryKeepsClearedOneTimeRecoveryLinkAndUndoRestoresUncategorized() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let categoryID = try service.createCategory(name: "Party", householdID: selection.householdID)
        let needID = try service.addOneTimeNeed(title: "Ice", categoryID: categoryID, listID: selection.listID)
        try service.setCarted(true, needID: needID)
        let token = try service.captureCarted(householdID: selection.householdID, listID: selection.listID)
        XCTAssertEqual(try service.clearCarted(using: token), 1)

        try service.removeCategory(categoryID: categoryID, householdID: selection.householdID)
        XCTAssertEqual(try service.undoClear(operationID: token.id), 1)

        let context = persistence.simulationContext()
        try context.performAndWait {
            let need = try fetch(Need.self, entity: "Need", id: needID, in: context)
            XCTAssertFalse(need.archived)
            XCTAssertNil(need.oneTimeCategory)
            XCTAssertNil(need.clearOperationID)
        }
    }

    func testCategoryManagementScopeUsesCanonicalListGraphAndRejectsGlobalDuplicateCategoryIDs() throws {
        let persistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold()
        let localCategoryID = try service.createCategory(name: "Local", householdID: local.householdID)
        try insertSecondaryCategoryGraph(
            householdID: local.householdID,
            listID: UUID(),
            categories: [(UUID(), "Foreign unique")],
            persistence: persistence
        )
        XCTAssertEqual(
            try scopedCategoryIDs(householdID: local.householdID, listID: local.listID, persistence: persistence),
            [localCategoryID]
        )

        try insertCategoryInSecondaryHousehold(
            id: localCategoryID, name: "Foreign duplicate", householdID: local.householdID, persistence: persistence
        )
        XCTAssertEqual(
            try scopedCategoryIDs(householdID: local.householdID, listID: local.listID, persistence: persistence),
            []
        )

        let duplicateListPersistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let duplicateListService = NeedService(persistence: duplicateListPersistence)
        let duplicateListLocal = try duplicateListService.createHousehold()
        _ = try duplicateListService.createCategory(name: "Local", householdID: duplicateListLocal.householdID)
        try insertSecondaryCategoryGraph(
            householdID: UUID(),
            listID: duplicateListLocal.listID,
            categories: [(UUID(), "Other graph")],
            persistence: duplicateListPersistence
        )
        let context = duplicateListPersistence.simulationContext()
        try context.performAndWait {
            let lists = try context.fetch(GroceryList.fetchRequest())
            XCTAssertNil(CategoryManagementScope.household(
                lists: lists,
                householdID: duplicateListLocal.householdID,
                listID: duplicateListLocal.listID
            ))
            XCTAssertTrue(CategoryManagementScope.validCategories(
                try context.fetch(Shopping.Category.fetchRequest()),
                lists: lists,
                householdID: duplicateListLocal.householdID,
                listID: duplicateListLocal.listID
            ).isEmpty)
        }
    }

    func testGroupingPreservesUrgencyThenGlobalCategoryOrderWithUncategorizedLast() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let bakery = try service.createCategory(name: "Bakery", householdID: selection.householdID, displayOrder: 1)
        let produce = try service.createCategory(name: "Produce", householdID: selection.householdID, displayOrder: 0)
        let produceItem = try service.createItem(name: "Apples", categoryID: produce, householdID: selection.householdID)
        let bakeryItem = try service.createItem(name: "Bread", categoryID: bakery, householdID: selection.householdID)
        let urgentProduce = try service.addRememberedNeed(itemID: produceItem, listID: selection.listID, urgency: .urgent)
        let urgentNone = try service.addOneTimeNeed(title: "Ice", urgency: .urgent, listID: selection.listID)
        let normalProduce = try service.addOneTimeNeed(title: "Carrots", categoryID: produce, listID: selection.listID)
        let normalBakery = try service.addRememberedNeed(itemID: bakeryItem, listID: selection.listID)
        let normalNone = try service.addOneTimeNeed(title: "Napkins", listID: selection.listID)

        let context = persistence.simulationContext()
        try context.performAndWait {
            let householdRequest = Household.fetchRequest()
            householdRequest.predicate = NSPredicate(format: "id == %@", selection.householdID as CVarArg)
            let household = try XCTUnwrap(context.fetch(householdRequest).first)
            let groups = CategoryGrouping.groups(
                needs: try context.fetch(Need.fetchRequest()),
                categories: try context.fetch(Shopping.Category.fetchRequest()),
                household: household
            )
            XCTAssertEqual(groups.map(\.urgency), [.urgent, .normal])
            XCTAssertEqual(groups[0].categories.map(\.title), ["Produce", "Uncategorized"])
            XCTAssertEqual(groups[0].categories.flatMap { $0.needs }.map(\.id), [urgentProduce, urgentNone])
            XCTAssertEqual(groups[1].categories.map(\.title), ["Produce", "Bakery", "Uncategorized"])
            XCTAssertEqual(groups[1].categories.flatMap { $0.needs }.map(\.id), [normalProduce, normalBakery, normalNone])
        }
    }

    private struct CategoryState: Equatable {
        let id: UUID
        let name: String
        let order: Int64
    }

    private func categoryStates(_ householdID: UUID, persistence: PersistenceController) throws -> [CategoryState] {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Shopping.Category.fetchRequest()
            request.predicate = NSPredicate(format: "household.id == %@", householdID as CVarArg)
            return try context.fetch(request).map { CategoryState(id: $0.id, name: $0.name, order: $0.displayOrder) }
                .sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        }
    }

    private func categoryName(_ id: UUID, persistence: PersistenceController) throws -> String {
        let context = persistence.simulationContext()
        return try context.performAndWait { try fetch(Shopping.Category.self, entity: "Category", id: id, in: context).name }
    }

    private func insertCategory(
        id: UUID,
        name: String,
        order: Int64,
        householdID: UUID,
        persistence: PersistenceController
    ) throws {
        let context = persistence.simulationContext()
        try context.performAndWait {
            let household = try fetch(Household.self, entity: "Household", id: householdID, in: context)
            let category = NSEntityDescription.insertNewObject(forEntityName: "Category", into: context) as! Shopping.Category
            category.id = id
            category.name = name
            category.displayOrder = order
            category.household = household
            try context.save()
        }
    }

    private func insertSecondaryCategoryGraph(
        householdID: UUID,
        listID: UUID,
        categories: [(UUID, String)],
        persistence: PersistenceController
    ) throws {
        let secondary = try XCTUnwrap(persistence.container.persistentStoreCoordinator.persistentStores.last)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let household = NSEntityDescription.insertNewObject(forEntityName: "Household", into: context) as! Household
            household.id = householdID
            household.name = "Imported duplicate"
            context.assign(household, to: secondary)
            let list = NSEntityDescription.insertNewObject(forEntityName: "GroceryList", into: context) as! GroceryList
            list.id = listID
            context.assign(list, to: secondary)
            list.household = household
            for (id, name) in categories {
                let category = NSEntityDescription.insertNewObject(forEntityName: "Category", into: context) as! Shopping.Category
                category.id = id
                category.name = name
                category.displayOrder = 0
                context.assign(category, to: secondary)
                category.household = household
            }
            try context.save()
        }
    }

    private func insertCategoryInSecondaryHousehold(
        id: UUID,
        name: String,
        householdID: UUID,
        persistence: PersistenceController
    ) throws {
        let secondary = try XCTUnwrap(persistence.container.persistentStoreCoordinator.persistentStores.last)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Household.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", householdID as CVarArg)
            let household = try XCTUnwrap(
                context.fetch(request).first(where: { $0.objectID.persistentStore == secondary })
            )
            let category = NSEntityDescription.insertNewObject(forEntityName: "Category", into: context) as! Shopping.Category
            category.id = id
            category.name = name
            category.displayOrder = 1
            context.assign(category, to: secondary)
            category.household = household
            try context.save()
        }
    }

    private func scopedCategoryIDs(
        householdID: UUID,
        listID: UUID,
        persistence: PersistenceController
    ) throws -> [UUID] {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            CategoryManagementScope.validCategories(
                try context.fetch(Shopping.Category.fetchRequest()),
                lists: try context.fetch(GroceryList.fetchRequest()),
                householdID: householdID,
                listID: listID
            ).map(\.id)
        }
    }

    private func fetch<T: NSManagedObject>(
        _ type: T.Type,
        entity: String,
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> T {
        let request = NSFetchRequest<T>(entityName: entity)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func makePersistence() throws -> PersistenceController {
        try PersistenceController(storeURL: temporaryStoreURL())
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingCategoryTests-\(UUID().uuidString).sqlite")
    }
}
