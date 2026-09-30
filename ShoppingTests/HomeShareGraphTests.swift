import CoreData
import XCTest
@testable import Shopping

final class HomeShareGraphTests: XCTestCase {
    func testCompleteGraphIncludesArchivedAndOneTimeDataButExcludesPrivateRecords() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let home = try service.createHousehold()
        let storeID = try service.createStore(name: "Store", householdID: home.householdID)
        let categoryID = try service.createCategory(name: "Category", householdID: home.householdID)
        let personID = try service.createPerson(name: "Person", householdID: home.householdID)
        let itemID = try service.createItem(name: "Milk", householdID: home.householdID)
        _ = try service.addRememberedNeed(itemID: itemID, listID: home.listID, householdID: home.householdID, quantity: nil)
        let context = persistence.container.viewContext
        try context.performAndWait {
            let root = try XCTUnwrap(context.fetch(Household.fetchRequest()).first)
            let store = try XCTUnwrap(context.fetch(Store.fetchRequest()).first { $0.id == storeID })
            let category = try XCTUnwrap(context.fetch(Category.fetchRequest()).first { $0.id == categoryID })
            let person = try XCTUnwrap(context.fetch(Person.fetchRequest()).first { $0.id == personID })
            let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first)
            item.stores = [store]; item.category = category; item.isArchived = true
            store.isArchived = true; category.isArchived = true; person.isArchived = true
            let need = Need(context: context)
            need.id = UUID(); need.title = "One-time"; need.kind = "oneTime"
            need.list = root.groceryList; need.person = person
            need.oneTimeCategory = category; need.oneTimeStores = [store]
            let clear = ClearOperation(context: context)
            clear.id = UUID(); clear.household = root; clear.list = root.groceryList
            let receipt = HouseholdCartRecord(context: context)
            receipt.id = UUID(); receipt.kind = "purchase"; receipt.household = root
            let personal = PersonalCartRecord(context: context)
            personal.id = UUID(); personal.accountBinding = "private-account"
            let legacy = LegacyCartReview(context: context)
            legacy.id = UUID()
            try context.save()
            let objects = try HomeShareGraphValidator.objects(root: root, listID: home.listID, in: context)
            XCTAssertEqual(Set(objects.compactMap { $0.entity.name }), HomeShareGraphValidator.sharedEntities)
            XCTAssertTrue(objects.contains(need)); XCTAssertTrue(objects.contains(receipt))
            XCTAssertTrue(objects.contains(store)); XCTAssertTrue(objects.contains(clear))
            XCTAssertFalse(objects.contains(personal)); XCTAssertFalse(objects.contains(legacy))
        }
    }

    func testCrossHomePurchaseRuleFailsBeforeSharingEitherGraph() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let first = try service.createHousehold(name: "First"), second = try service.createHousehold(name: "Second")
        _ = try service.createItem(name: "Milk", householdID: first.householdID)
        _ = try service.createStore(name: "Foreign", householdID: second.householdID)
        let context = persistence.container.viewContext
        try context.performAndWait {
            let root = try XCTUnwrap(context.fetch(Household.fetchRequest()).first { $0.id == first.householdID })
            let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first)
            item.stores = Set(try context.fetch(Store.fetchRequest()))
            try context.save()
            XCTAssertThrowsError(try HomeShareGraphValidator.objects(root: root, listID: first.listID, in: context)) {
                XCTAssertEqual($0 as? HomeShareGraphValidator.Failure, .foreignObject)
            }
        }
    }

    func testDuplicateChildIdentityAndMissingRequiredListFailClosed() throws {
        let persistence = try PersistenceController(inMemory: true)
        let home = try NeedService(persistence: persistence).createHousehold()
        let context = persistence.container.viewContext
        try context.performAndWait {
            let root = try XCTUnwrap(context.fetch(Household.fetchRequest()).first)
            let id = UUID()
            for _ in 0..<2 {
                let category = Category(context: context)
                category.id = id; category.household = root
            }
            try context.save()
            XCTAssertThrowsError(try HomeShareGraphValidator.objects(root: root, listID: home.listID, in: context)) {
                XCTAssertEqual($0 as? HomeShareGraphValidator.Failure, .ambiguousIdentity)
            }
            root.groceryList = nil
            try context.save()
            XCTAssertThrowsError(try HomeShareGraphValidator.objects(root: root, listID: home.listID, in: context)) {
                XCTAssertEqual($0 as? HomeShareGraphValidator.Failure, .incompleteHome)
            }
        }
    }
}
