import CoreData
import XCTest
@testable import Shopping

final class PersistenceHarnessTests: XCTestCase {
    func testExplicitSameValueEditAdvancesRevision() throws {
        let persistence = try sqlitePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let needID = try service.addOneTimeNeed(title: "Milk", listID: ids.listID)
        try service.setCarted(false, needID: needID)
        try service.setCarted(false, needID: needID)
        let state = try needState(needID, in: persistence.simulationContext())
        XCTAssertEqual(state.revision, 2, "Each explicit edit records fresh user intent")
        XCTAssertFalse(state.carted)
    }

    func testTwoSQLiteContextsPreserveDisjointEditsInBothSaveOrders() throws {
        for cartSavesFirst in [true, false] {
            let persistence = try sqlitePersistence()
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            let needID = try service.addOneTimeNeed(title: "Apples", listID: ids.listID)
            let cartContext = persistence.simulationContext()
            let quantityContext = persistence.simulationContext()
            try loadNeed(needID, in: cartContext)
            try loadNeed(needID, in: quantityContext)

            try stageNeed(needID, in: cartContext) { $0.carted = true }
            try stageNeed(needID, in: quantityContext) { $0.quantity = 4 }
            if cartSavesFirst {
                try save(cartContext)
                try save(quantityContext)
            } else {
                try save(quantityContext)
                try save(cartContext)
            }
            let merged = try needState(needID, in: persistence.simulationContext())
            XCTAssertTrue(merged.carted)
            XCTAssertEqual(merged.quantity, 4)
        }
    }

    func testCompetingSQLiteTagAdditionsMergeAsAUnion() throws {
        let persistence = try sqlitePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let storeA = try service.createStore(name: "Aldi", householdID: ids.householdID)
        let storeB = try service.createStore(name: "Costco", householdID: ids.householdID)
        let storeC = try service.createStore(name: "Publix", householdID: ids.householdID)
        let itemID = try service.createItem(
            name: "Rice",
            storeIDs: [storeA],
            householdID: ids.householdID,
            anyStore: false
        )
        let first = persistence.simulationContext()
        let second = persistence.simulationContext()
        try loadItem(itemID, in: first)
        try loadItem(itemID, in: second)
        try stageItem(itemID, in: first) { item, context in
            item.mutableSetValue(forKey: "stores").add(try self.fetchStore(storeB, in: context))
        }
        try stageItem(itemID, in: second) { item, context in
            item.mutableSetValue(forKey: "stores").add(try self.fetchStore(storeC, in: context))
        }
        try save(first)
        try save(second)
        let state = try itemState(itemID, in: persistence.simulationContext())
        XCTAssertEqual(state.storeIDs, [storeA, storeB, storeC])
        XCTAssertFalse(state.anyStore)
    }

    func testCompetingSamePropertySQLiteEditsUseLastLocalSave() throws {
        let persistence = try sqlitePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let needID = try service.addOneTimeNeed(title: "Oranges", listID: ids.listID)
        let first = persistence.simulationContext()
        let second = persistence.simulationContext()
        try loadNeed(needID, in: first)
        try loadNeed(needID, in: second)
        try stageNeed(needID, in: first) { $0.quantity = 2 }
        try stageNeed(needID, in: second) { $0.quantity = 5 }
        try save(first)
        try save(second)
        XCTAssertEqual(try needState(needID, in: persistence.simulationContext()).quantity, 5)
    }

    func testClearSkipsExternalRevisionChangeAndNewlyCartedNeed() throws {
        let persistence = try sqlitePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let changedID = try service.addOneTimeNeed(title: "Changed", listID: ids.listID)
        let stableID = try service.addOneTimeNeed(title: "Stable", listID: ids.listID)
        let newlyCartedID = try service.addOneTimeNeed(title: "Later", listID: ids.listID)
        try service.setCarted(true, needID: changedID)
        try service.setCarted(true, needID: stableID)
        let token = try service.captureCarted(householdID: ids.householdID, listID: ids.listID)

        let external = persistence.simulationContext()
        try mutateNeed(changedID, in: external) {
            $0.quantity = 2
            $0.revision += 1
        }
        try mutateNeed(newlyCartedID, in: external) {
            $0.carted = true
            $0.revision += 1
        }
        XCTAssertEqual(try service.clearCarted(using: token), 1)
        XCTAssertEqual(try service.clearCarted(using: token), 0, "Replaying a token is idempotent")
        XCTAssertFalse(try needState(changedID, in: persistence.simulationContext()).archived)
        XCTAssertTrue(try needState(stableID, in: persistence.simulationContext()).archived)
        XCTAssertFalse(try needState(newlyCartedID, in: persistence.simulationContext()).archived)
    }

    func testOneTimeClearUndoSurvivesSQLiteRelaunch() throws {
        let storeURL = temporaryStoreURL()
        var operationID: UUID!
        var needID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: storeURL)
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            needID = try service.addOneTimeNeed(title: "Party ice", listID: ids.listID)
            try service.setCarted(true, needID: needID)
            let token = try service.captureCarted(householdID: ids.householdID, listID: ids.listID)
            operationID = token.id
            XCTAssertEqual(try service.clearCarted(using: token), 1)
        }
        do {
            let relaunched = try PersistenceController(storeURL: storeURL)
            let service = NeedService(persistence: relaunched)
            XCTAssertEqual(try service.undoClear(operationID: operationID), 1)
            let restored = try needState(needID, in: relaunched.simulationContext())
            XCTAssertFalse(restored.archived)
            XCTAssertTrue(restored.carted)
        }
    }

    func testRelaunchUndoRefusesDuplicateActiveRememberedNeed() throws {
        let storeURL = temporaryStoreURL()
        var operationID: UUID!
        var originalID: UUID!
        var replacementID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: storeURL)
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            let itemID = try service.createItem(name: "Bread", householdID: ids.householdID)
            originalID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
            try service.setCarted(true, needID: originalID)
            let token = try service.captureCarted(householdID: ids.householdID, listID: ids.listID)
            operationID = token.id
            XCTAssertEqual(try service.clearCarted(using: token), 1)
            replacementID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
        }
        do {
            let relaunched = try PersistenceController(storeURL: storeURL)
            let service = NeedService(persistence: relaunched)
            XCTAssertEqual(try service.undoClear(operationID: operationID), 0)
            XCTAssertTrue(try needState(originalID, in: relaunched.simulationContext()).archived)
            XCTAssertFalse(try needState(replacementID, in: relaunched.simulationContext()).archived)
        }
    }

    func testRememberedDuplicateIsReusedAndOneTimeNeedDoesNotSeedCatalog() throws {
        let persistence = try sqlitePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let itemID = try service.createItem(name: "Bread", householdID: ids.householdID)
        let firstID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
        let secondID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
        let oneTimeID = try service.addOneTimeNeed(title: "Party ice", listID: ids.listID)
        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(try needState(firstID, in: persistence.simulationContext()).revision, 1)
        XCTAssertNil(try needState(oneTimeID, in: persistence.simulationContext()).itemID)
        XCTAssertEqual(try count(Item.fetchRequest(), in: persistence.simulationContext()), 1)
    }

    func testCommandsRejectCrossHouseholdRelationshipsAndInvalidQuantity() throws {
        let persistence = try sqlitePersistence()
        let service = NeedService(persistence: persistence)
        let first = try service.createHousehold(name: "First")
        let second = try service.createHousehold(name: "Second")
        let itemID = try service.createItem(name: "Milk", householdID: first.householdID)
        let foreignStoreID = try service.createStore(name: "Foreign", householdID: second.householdID)
        XCTAssertThrowsError(try service.addRememberedNeed(itemID: itemID, listID: second.listID))
        XCTAssertThrowsError(try service.setStoreTags(itemID: itemID, storeIDs: [foreignStoreID]))
        let needID = try service.addOneTimeNeed(title: "Milk", listID: first.listID)
        XCTAssertThrowsError(try service.setQuantity(0, needID: needID))
    }

    func testStoreArchiveAndRestorePreserveRememberedMembershipAndNeedAcrossRelaunch() throws {
        let storeURL = temporaryStoreURL()
        var householdID: UUID!
        var storeID: UUID!
        var itemID: UUID!
        var needID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: storeURL)
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            householdID = ids.householdID
            storeID = try service.createStore(name: " Costco ", householdID: householdID)
            itemID = try service.createItem(
                name: "Olive oil",
                storeIDs: [storeID],
                householdID: householdID,
                anyStore: false
            )
            needID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
            try service.setQuantity(3, needID: needID)
            try service.setCarted(true, needID: needID)
            try service.setStoreArchived(true, storeID: storeID, householdID: householdID)
            XCTAssertEqual(try service.storeEligibility(itemID: itemID), .needsStore)
        }

        let relaunched = try PersistenceController(storeURL: storeURL)
        let service = NeedService(persistence: relaunched)
        XCTAssertEqual(try itemState(itemID, in: relaunched.simulationContext()).storeIDs, [storeID])
        let savedNeed = try needState(needID, in: relaunched.simulationContext())
        XCTAssertEqual(savedNeed.quantity, 3)
        XCTAssertTrue(savedNeed.carted)
        try service.setStoreArchived(false, storeID: storeID, householdID: householdID)
        XCTAssertEqual(try service.storeEligibility(itemID: itemID), .activeStores([storeID]))
    }

    func testRemovingCategoryNullifiesItemAndPreservesCatalogAndNeed() throws {
        let persistence = try sqlitePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let categoryID = try service.createCategory(name: " Produce ", householdID: ids.householdID)
        let itemID = try service.createItem(name: "Apples", householdID: ids.householdID)
        try service.setCategory(itemID: itemID, categoryID: categoryID)
        let needID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
        try service.setQuantity(4, needID: needID)

        try service.removeCategory(categoryID: categoryID, householdID: ids.householdID)

        let context = persistence.simulationContext()
        try context.performAndWait {
            let item = try self.fetchItem(itemID, in: context)
            XCTAssertNil(item.category)
            XCTAssertEqual(item.needs?.map(\.id), [needID])
            XCTAssertEqual(try self.fetchNeed(needID, in: context).quantity, 4)
            XCTAssertEqual(try context.count(for: Category.fetchRequest()), 0)
        }
    }

    func testNamesAreTrimmedNonblankAndOrderTiesUseUUID() throws {
        let persistence = try sqlitePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        XCTAssertThrowsError(try service.createStore(name: " \n ", householdID: ids.householdID))
        XCTAssertThrowsError(try service.createCategory(name: "", householdID: ids.householdID))
        let firstID = try service.createStore(name: " Same ", householdID: ids.householdID, displayOrder: 2)
        let secondID = try service.createStore(name: "Same", householdID: ids.householdID, displayOrder: 2)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let stores = try context.fetch(Store.fetchRequest()).sorted(by: NeedService.storeDisplayOrder)
            XCTAssertEqual(stores.map(\.id), [firstID, secondID].sorted { $0.uuidString < $1.uuidString })
            XCTAssertEqual(Set(stores.map(\.name)), ["Same"])
        }
    }

    func testCategoryAssignmentRejectsForeignHouseholdAtomicallyAndAllowsUnlink() throws {
        let persistence = try sqlitePersistence()
        let service = NeedService(persistence: persistence)
        let first = try service.createHousehold()
        let second = try service.createHousehold()
        let localCategory = try service.createCategory(name: "Local", householdID: first.householdID)
        let foreignCategory = try service.createCategory(name: "Foreign", householdID: second.householdID)
        let itemID = try service.createItem(name: "Milk", householdID: first.householdID)
        try service.setCategory(itemID: itemID, categoryID: localCategory)
        XCTAssertThrowsError(try service.setCategory(itemID: itemID, categoryID: foreignCategory))
        XCTAssertEqual(try itemCategoryID(itemID, in: persistence.simulationContext()), localCategory)
        try service.setCategory(itemID: itemID, categoryID: nil)
        XCTAssertNil(try itemCategoryID(itemID, in: persistence.simulationContext()))
    }

    func testOwnedGraphCommandsStayInHouseholdsPersistentStore() throws {
        let firstURL = temporaryStoreURL()
        let secondURL = temporaryStoreURL()
        let persistence = try PersistenceController(storeURL: firstURL, additionalStoreURLs: [secondURL])
        let secondStore = try XCTUnwrap(persistence.container.persistentStoreCoordinator.persistentStores.last)
        let setup = persistence.simulationContext()
        let householdID = UUID()
        let listID = UUID()
        try setup.performAndWait {
            let household = Household(context: setup)
            household.id = householdID
            household.name = "Imported household"
            setup.assign(household, to: secondStore)
            let list = GroceryList(context: setup)
            list.id = listID
            setup.assign(list, to: secondStore)
            list.household = household
            try setup.save()
        }

        let service = NeedService(persistence: persistence)
        let storeID = try service.createStore(name: "Costco", householdID: householdID)
        let categoryID = try service.createCategory(name: "Pantry", householdID: householdID)
        let itemID = try service.createItem(name: "Rice", householdID: householdID)
        try service.setCategory(itemID: itemID, categoryID: categoryID)
        let needID = try service.addRememberedNeed(itemID: itemID, listID: listID)

        let verify = persistence.simulationContext()
        try verify.performAndWait {
            let objects: [NSManagedObject] = [
                try self.fetchStore(storeID, in: verify),
                try self.fetchItem(itemID, in: verify),
                try self.fetchNeed(needID, in: verify)
            ]
            let categoryRequest = Category.fetchRequest()
            categoryRequest.predicate = NSPredicate(format: "id == %@", categoryID as CVarArg)
            objects.forEach { XCTAssertEqual($0.objectID.persistentStore, secondStore) }
            XCTAssertEqual(try XCTUnwrap(verify.fetch(categoryRequest).first).objectID.persistentStore, secondStore)
        }
    }

    func testFailedFirstStoreIsNotHiddenBySuccessfulSecondStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShoppingLoadFailure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidParent = directory.appendingPathComponent("file-not-directory")
        try Data("file".utf8).write(to: invalidParent)
        let validURL = directory.appendingPathComponent("valid.sqlite")
        XCTAssertThrowsError(try PersistenceController(
            storeURL: invalidParent.appendingPathComponent("invalid.sqlite"),
            additionalStoreURLs: [validURL]
        ))
        XCTAssertThrowsError(try PersistenceController(additionalStoreURLs: [validURL]))
    }

    private typealias NeedState = (revision: Int64, carted: Bool, quantity: Int64, archived: Bool, itemID: UUID?)
    private typealias ItemState = (storeIDs: Set<UUID>, anyStore: Bool)

    private func sqlitePersistence() throws -> PersistenceController {
        try PersistenceController(storeURL: temporaryStoreURL())
    }

    private func loadNeed(_ id: UUID, in context: NSManagedObjectContext) throws {
        try context.performAndWait { _ = try fetchNeed(id, in: context) }
    }

    private func loadItem(_ id: UUID, in context: NSManagedObjectContext) throws {
        try context.performAndWait { _ = try fetchItem(id, in: context) }
    }

    private func mutateNeed(_ id: UUID, in context: NSManagedObjectContext, change: @escaping (Need) -> Void) throws {
        try context.performAndWait {
            change(try fetchNeed(id, in: context))
            try context.save()
        }
    }

    private func stageNeed(_ id: UUID, in context: NSManagedObjectContext, change: @escaping (Need) -> Void) throws {
        try context.performAndWait { change(try fetchNeed(id, in: context)) }
    }

    private func stageItem(_ id: UUID, in context: NSManagedObjectContext, change: @escaping (Item, NSManagedObjectContext) throws -> Void) throws {
        try context.performAndWait {
            try change(fetchItem(id, in: context), context)
        }
    }

    private func save(_ context: NSManagedObjectContext) throws {
        try context.performAndWait { try context.save() }
    }

    private func needState(_ id: UUID, in context: NSManagedObjectContext) throws -> NeedState {
        try context.performAndWait {
            let need = try fetchNeed(id, in: context)
            return (need.revision, need.carted, need.quantity, need.archived, need.item?.id)
        }
    }

    private func itemState(_ id: UUID, in context: NSManagedObjectContext) throws -> ItemState {
        try context.performAndWait {
            let item = try fetchItem(id, in: context)
            return (Set(item.stores?.map(\.id) ?? []), item.anyStore)
        }
    }

    private func itemCategoryID(_ id: UUID, in context: NSManagedObjectContext) throws -> UUID? {
        try context.performAndWait { try fetchItem(id, in: context).category?.id }
    }

    private func count<T>(_ request: NSFetchRequest<T>, in context: NSManagedObjectContext) throws -> Int {
        try context.performAndWait { try context.count(for: request) }
    }

    private func fetchNeed(_ id: UUID, in context: NSManagedObjectContext) throws -> Need {
        let request = Need.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func fetchItem(_ id: UUID, in context: NSManagedObjectContext) throws -> Item {
        let request = Item.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func fetchStore(_ id: UUID, in context: NSManagedObjectContext) throws -> Store {
        let request = Store.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingTests-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }
}
