import CoreData
import XCTest

@testable import Shopping

final class ManagementWriterScopeTests: XCTestCase {
    func testCategoryAndCatalogWritersRejectDuplicateListImportedAfterStaleUISnapshot() throws {
        let persistence = try PersistenceController(
            storeURL: temporaryStoreURL(), additionalStoreURLs: [temporaryStoreURL()]
        )
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold(name: "Local")
        let firstCategory = try service.createCategory(
            name: "First", householdID: selection.householdID, displayOrder: 0)
        let secondCategory = try service.createCategory(
            name: "Second", householdID: selection.householdID, displayOrder: 1)
        let itemID = try service.createCatalogItem(
            values: catalog(name: "Tea", notes: "Original", categoryID: firstCategory),
            householdID: selection.householdID
        )
        let needID = try service.addOneTimeNeed(
            title: "Ice", categoryID: firstCategory, listID: selection.listID
        )

        let staleUIContext = persistence.simulationContext()
        let staleObjectIDs = try staleUIContext.performAndWait {
            let lists = try staleUIContext.fetch(PurchaseRulesStoreScope.listsRequest())
            let households = try staleUIContext.fetch(NavigationFetchRequests.households())
            XCTAssertNotNil(
                CategoryManagementScope.household(
                    lists: lists, households: households,
                    householdID: selection.householdID, listID: selection.listID
                ))
            return (
                listIDs: lists.map(\.objectID),
                householdIDs: households.map(\.objectID)
            )
        }
        let before = try snapshot(
            householdID: selection.householdID, needID: needID, persistence: persistence
        )

        try insertDuplicateList(
            selection.listID, intoSecondaryStoreOf: persistence
        )
        try staleUIContext.performAndWait {
            let staleLists = try staleObjectIDs.listIDs.map {
                try XCTUnwrap(staleUIContext.existingObject(with: $0) as? GroceryList)
            }
            let staleHouseholds = try staleObjectIDs.householdIDs.map {
                try XCTUnwrap(staleUIContext.existingObject(with: $0) as? Household)
            }
            XCTAssertNotNil(
                CategoryManagementScope.household(
                    lists: staleLists, households: staleHouseholds,
                    householdID: selection.householdID,
                    listID: selection.listID
                ),
                "The retained UI result deliberately remains stale after the import"
            )
        }

        assertScopeChanged {
            try service.createCategory(
                name: "Must not exist", householdID: selection.householdID,
                listID: selection.listID)
        }
        assertScopeChanged {
            try service.renameCategory(
                name: "Must not rename", categoryID: firstCategory,
                householdID: selection.householdID, listID: selection.listID)
        }
        assertScopeChanged {
            try service.removeCategory(
                categoryID: firstCategory, householdID: selection.householdID,
                listID: selection.listID)
        }
        assertScopeChanged {
            try service.reorderCategories(
                [secondCategory, firstCategory], householdID: selection.householdID,
                listID: selection.listID)
        }
        assertScopeChanged {
            try service.createCatalogItem(
                values: catalog(name: "Coffee"), householdID: selection.householdID,
                listID: selection.listID)
        }
        assertScopeChanged {
            try service.saveCatalogItem(
                itemID: itemID, householdID: selection.householdID,
                listID: selection.listID,
                values: catalog(name: "Must not save", notes: "Changed"))
        }
        assertScopeChanged {
            try service.setCatalogItemArchived(
                itemID: itemID, householdID: selection.householdID,
                listID: selection.listID, archived: true)
        }

        XCTAssertEqual(
            try snapshot(
                householdID: selection.householdID, needID: needID,
                persistence: persistence
            ),
            before
        )
    }

    func testValidScopedCategoryAndCatalogCommandsStillWriteNormally() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold(name: "Local")
        let first = try service.createCategory(
            name: "First", householdID: selection.householdID,
            listID: selection.listID, displayOrder: 0
        )
        let second = try service.createCategory(
            name: "Second", householdID: selection.householdID,
            listID: selection.listID, displayOrder: 1
        )
        try service.renameCategory(
            name: "Renamed", categoryID: first, householdID: selection.householdID,
            listID: selection.listID
        )
        try service.reorderCategories(
            [second, first], householdID: selection.householdID,
            listID: selection.listID
        )
        let itemID = try service.createCatalogItem(
            values: catalog(name: "Tea", categoryID: first),
            householdID: selection.householdID, listID: selection.listID
        )
        try service.saveCatalogItem(
            itemID: itemID, householdID: selection.householdID,
            listID: selection.listID,
            values: catalog(name: "Green tea", notes: "Loose leaf", categoryID: first)
        )
        try service.setCatalogItemArchived(
            itemID: itemID, householdID: selection.householdID,
            listID: selection.listID, archived: true
        )
        try service.removeCategory(
            categoryID: first, householdID: selection.householdID,
            listID: selection.listID
        )

        let context = persistence.simulationContext()
        try context.performAndWait {
            let categoryRequest = Category.fetchRequest()
            let categories = try context.fetch(categoryRequest)
            XCTAssertEqual(categories.map(\.id), [second])
            XCTAssertEqual(categories.first?.displayOrder, 0)
            let itemRequest = Item.fetchRequest()
            itemRequest.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            let item = try XCTUnwrap(context.fetch(itemRequest).first)
            XCTAssertEqual(item.name, "Green tea")
            XCTAssertEqual(item.notes, "Loose leaf")
            XCTAssertTrue(item.isArchived)
            XCTAssertNil(item.category)
        }
    }

    private struct Snapshot: Equatable {
        let categoryNames: [UUID: String]
        let categoryOrders: [UUID: Int64]
        let itemNames: [UUID: String]
        let itemNotes: [UUID: String]
        let itemArchived: [UUID: Bool]
        let itemCategoryIDs: [UUID: UUID?]
        let needCategoryID: UUID?
        let needRevision: Int64
    }

    private func snapshot(
        householdID: UUID,
        needID: UUID,
        persistence: PersistenceController
    ) throws -> Snapshot {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let categoryRequest = Category.fetchRequest()
            categoryRequest.predicate = NSPredicate(
                format: "household.id == %@", householdID as CVarArg)
            let categories = try context.fetch(categoryRequest)
            let itemRequest = Item.fetchRequest()
            itemRequest.predicate = NSPredicate(
                format: "household.id == %@", householdID as CVarArg)
            let items = try context.fetch(itemRequest)
            let needRequest = Need.fetchRequest()
            needRequest.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let need = try XCTUnwrap(context.fetch(needRequest).first)
            return Snapshot(
                categoryNames: Dictionary(
                    uniqueKeysWithValues: categories.map { ($0.id, $0.name) }),
                categoryOrders: Dictionary(
                    uniqueKeysWithValues: categories.map { ($0.id, $0.displayOrder) }),
                itemNames: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) }),
                itemNotes: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.notes) }),
                itemArchived: Dictionary(
                    uniqueKeysWithValues: items.map { ($0.id, $0.isArchived) }),
                itemCategoryIDs: Dictionary(
                    uniqueKeysWithValues: items.map { ($0.id, $0.category?.id) }),
                needCategoryID: need.oneTimeCategory?.id,
                needRevision: need.revision
            )
        }
    }

    private func catalog(
        name: String,
        notes: String = "",
        categoryID: UUID? = nil
    ) -> CatalogItemValues {
        CatalogItemValues(
            name: name, notes: notes, categoryID: categoryID,
            anyStore: true, storeIDs: []
        )
    }

    private func assertScopeChanged<T>(_ body: () throws -> T) {
        XCTAssertThrowsError(try body()) {
            XCTAssertEqual($0 as? NeedServiceError, .scopeChanged)
        }
    }

    private func insertDuplicateList(
        _ listID: UUID,
        intoSecondaryStoreOf persistence: PersistenceController
    ) throws {
        let secondary = try XCTUnwrap(
            persistence.container.persistentStoreCoordinator.persistentStores.last)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let household =
                NSEntityDescription.insertNewObject(
                    forEntityName: "Household", into: context) as! Household
            household.id = UUID()
            household.name = "Imported"
            context.assign(household, to: secondary)
            let list =
                NSEntityDescription.insertNewObject(
                    forEntityName: "GroceryList", into: context) as! GroceryList
            list.id = listID
            context.assign(list, to: secondary)
            list.household = household
            try context.save()
        }
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ShoppingManagementWriterScope-\(UUID().uuidString).sqlite")
    }
}
