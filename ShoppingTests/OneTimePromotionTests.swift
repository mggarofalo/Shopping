import CoreData
import XCTest

@testable import Shopping

final class OneTimePromotionTests: XCTestCase {
    func testCreatingPromotionPreservesOccurrenceAndSeparatesCatalogFromCurrentNeed() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let store = try service.createStore(name: "Costco", householdID: ids.householdID)
        let category = try service.createCategory(name: "Pantry", householdID: ids.householdID)
        let needID = try service.addOneTimeNeed(
            title: "Tea", notes: "old", quantity: 2, urgency: .normal,
            householdID: ids.householdID, listID: ids.listID
        )
        try service.setCarted(true, needID: needID)
        let oldRevision = try snapshot(needID, persistence).revision

        let itemID = try service.rememberOneTimeGroceryCreatingItem(
            needID: needID, householdID: ids.householdID, listID: ids.listID,
            catalog: CatalogItemValues(
                name: " Green tea ", notes: " Catalog note ", categoryID: category,
                anyStore: false, storeIDs: [store]
            ),
            need: RememberedNeedValues(quantity: 3, purchaseNotes: " Need note ", urgency: .urgent)
        )
        let value = try snapshot(needID, persistence)
        XCTAssertEqual(value.id, needID)
        XCTAssertEqual(value.itemID, itemID)
        XCTAssertEqual(value.kind, .remembered)
        XCTAssertEqual(value.title, "Green tea")
        XCTAssertEqual(value.quantity, 3)
        XCTAssertEqual(value.notes, "Need note")
        XCTAssertEqual(value.urgency, .urgent)
        XCTAssertTrue(value.carted)
        XCTAssertEqual(value.revision, oldRevision + 1)
        XCTAssertNil(value.clearOperationID)
        XCTAssertEqual(value.itemNotes, "Catalog note")
        XCTAssertEqual(value.itemCategoryID, category)
        XCTAssertEqual(value.itemStoreIDs, [store])
        XCTAssertFalse(value.itemAnyStore)
        XCTAssertTrue(value.oneTimeStoreIDs.isEmpty)
        XCTAssertNil(value.oneTimeCategoryID)
    }

    func testLinkPreservesCatalogRulesAndActiveConflictPreservesBothNeeds() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let store = try service.createStore(name: "Aldi", householdID: ids.householdID)
        let itemID = try service.createItem(
            name: "Rice", notes: "Catalog", storeIDs: [store], householdID: ids.householdID,
            anyStore: false
        )
        let oneTimeID = try service.addOneTimeNeed(
            title: "Rice copy", notes: "old", listID: ids.listID)
        XCTAssertEqual(
            try service.rememberOneTimeGrocery(
                needID: oneTimeID, householdID: ids.householdID, listID: ids.listID,
                existingItemID: itemID,
                need: RememberedNeedValues(quantity: 7, purchaseNotes: "Need", urgency: .urgent)
            ), itemID)
        let linked = try snapshot(oneTimeID, persistence)
        XCTAssertEqual(linked.itemNotes, "Catalog")
        XCTAssertEqual(linked.itemStoreIDs, [store])
        XCTAssertFalse(linked.itemAnyStore)
        XCTAssertEqual(linked.notes, "Need")
        XCTAssertEqual(linked.quantity, 7)
        XCTAssertEqual(linked.urgency, .urgent)

        let later = try service.addOneTimeNeed(
            title: "Special rice", notes: "Keep", listID: ids.listID)
        let before = try snapshot(later, persistence)
        assertError(.activeRememberedNeedConflict(oneTimeID)) {
            try service.rememberOneTimeGrocery(
                needID: later, householdID: ids.householdID, listID: ids.listID,
                existingItemID: itemID, need: RememberedNeedValues()
            )
        }
        XCTAssertEqual(try snapshot(later, persistence), before)
        XCTAssertEqual(try service.allActiveNeedIDs(householdID: ids.householdID).count, 2)
    }

    func testLinkRejectsDuplicateActiveNeedsAndDuplicateCatalogIdentity() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let itemID = try service.createItem(name: "Rice", householdID: ids.householdID)
        _ = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
        try insertRemembered(itemID: itemID, listID: ids.listID, persistence: persistence)
        let oneTimeID = try service.addOneTimeNeed(title: "Rice", listID: ids.listID)
        let before = try snapshot(oneTimeID, persistence)
        XCTAssertThrowsError(
            try service.rememberOneTimeGrocery(
                needID: oneTimeID, householdID: ids.householdID, listID: ids.listID,
                existingItemID: itemID, need: RememberedNeedValues()
            )
        ) {
            guard let error = $0 as? NeedServiceError,
                case .activeRememberedNeedDuplicates(let group) = error
            else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(group.itemID, itemID)
            XCTAssertEqual(group.candidates.count, 2)
        }
        XCTAssertEqual(try snapshot(oneTimeID, persistence), before)

        let clean = try PersistenceController(inMemory: true)
        let cleanService = NeedService(persistence: clean)
        let cleanIDs = try cleanService.createHousehold()
        let cleanNeed = try cleanService.addOneTimeNeed(title: "Tea", listID: cleanIDs.listID)
        let cleanItem = try cleanService.createItem(name: "Tea", householdID: cleanIDs.householdID)
        try duplicateItem(cleanItem, persistence: clean)
        assertError(.invalidCatalogIdentity) {
            try cleanService.rememberOneTimeGrocery(
                needID: cleanNeed, householdID: cleanIDs.householdID, listID: cleanIDs.listID,
                existingItemID: cleanItem, need: RememberedNeedValues()
            )
        }
    }

    func testPromotionRejectsForeignArchivedWrongKindArchivedNeedAndWrongScope() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold()
        let foreign = try service.createHousehold()
        let needID = try service.addOneTimeNeed(title: "Milk", listID: local.listID)
        let foreignItem = try service.createItem(name: "Foreign", householdID: foreign.householdID)
        assertError(.scopeChanged) {
            try service.rememberOneTimeGrocery(
                needID: needID, householdID: local.householdID, listID: local.listID,
                existingItemID: foreignItem, need: RememberedNeedValues()
            )
        }
        let archived = try service.createItem(name: "Archived", householdID: local.householdID)
        try service.setCatalogItemArchived(
            itemID: archived, householdID: local.householdID, archived: true)
        assertError(.itemArchived) {
            try service.rememberOneTimeGrocery(
                needID: needID, householdID: local.householdID, listID: local.listID,
                existingItemID: archived, need: RememberedNeedValues()
            )
        }
        assertError(.scopeChanged) {
            try service.rememberOneTimeGroceryCreatingItem(
                needID: needID, householdID: foreign.householdID, listID: local.listID,
                catalog: catalog("Milk"), need: RememberedNeedValues()
            )
        }
        let remembered = try service.addRememberedNeed(
            itemID: try service.createItem(name: "Bread", householdID: local.householdID),
            listID: local.listID
        )
        assertError(.scopeChanged) {
            try service.rememberOneTimeGroceryCreatingItem(
                needID: remembered, householdID: local.householdID, listID: local.listID,
                catalog: catalog("Bread 2"), need: RememberedNeedValues()
            )
        }
        try mutateNeed(needID, persistence: persistence) { $0.archived = true }
        assertError(.scopeChanged) {
            try service.rememberOneTimeGroceryCreatingItem(
                needID: needID, householdID: local.householdID, listID: local.listID,
                catalog: catalog("Milk"), need: RememberedNeedValues()
            )
        }
    }

    func testCanonicalIdentityRejectsDuplicateNeedHouseholdAndListIDs() throws {
        for entity in ["Need", "Household", "GroceryList"] {
            let persistence = try PersistenceController(inMemory: true)
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            let needID = try service.addOneTimeNeed(title: "Tea", listID: ids.listID)
            try insertDuplicate(
                entity,
                id: entity == "Need"
                    ? needID : entity == "Household" ? ids.householdID : ids.listID,
                persistence: persistence)
            assertError(entity == "Need" ? .invalidOccurrenceIdentity : .scopeChanged) {
                try service.rememberOneTimeGroceryCreatingItem(
                    needID: needID, householdID: ids.householdID, listID: ids.listID,
                    catalog: catalog("Tea"), need: RememberedNeedValues()
                )
            }
        }
    }

    func testCollisionNeedsExplicitDistinctChoiceAndOverflowRollsBackEverything() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let existing = try service.createItem(name: "Sparkling Water", householdID: ids.householdID)
        let needID = try service.addOneTimeNeed(
            title: "Party water", notes: "Keep", listID: ids.listID)
        let before = try snapshot(needID, persistence)
        let values = catalog("  sparkling   water ", notes: "Lime")
        assertError(.catalogNameCollision([existing])) {
            try service.rememberOneTimeGroceryCreatingItem(
                needID: needID, householdID: ids.householdID, listID: ids.listID,
                catalog: values, need: RememberedNeedValues(quantity: 2)
            )
        }
        XCTAssertEqual(try snapshot(needID, persistence), before)
        let distinct = try service.rememberOneTimeGroceryCreatingItem(
            needID: needID, householdID: ids.householdID, listID: ids.listID,
            catalog: values, need: RememberedNeedValues(quantity: 2),
            allowingCatalogNameCollision: true
        )
        XCTAssertNotEqual(distinct, existing)

        let overflowID = try service.addOneTimeNeed(
            title: "Overflow", notes: "Keep", listID: ids.listID)
        try mutateNeed(overflowID, persistence: persistence) { $0.revision = .max }
        let overflowBefore = try snapshot(overflowID, persistence)
        assertError(.scopeChanged) {
            try service.rememberOneTimeGroceryCreatingItem(
                needID: overflowID, householdID: ids.householdID, listID: ids.listID,
                catalog: catalog("Overflow item"), need: RememberedNeedValues()
            )
        }
        XCTAssertEqual(try snapshot(overflowID, persistence), overflowBefore)
        XCTAssertEqual(
            Set(try service.allCatalogItemIDs(householdID: ids.householdID)), [existing, distinct])
    }

    func testInjectedSaveFailureIsAtomicAcrossSQLiteReopen() throws {
        let url = temporaryStoreURL()
        var ids: (householdID: UUID, listID: UUID)!
        var needID: UUID!
        var before: Snapshot!
        do {
            let persistence = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: persistence)
            ids = try service.createHousehold()
            needID = try service.addOneTimeNeed(title: "Tea", notes: "Keep", listID: ids.listID)
            before = try snapshot(needID, persistence)
        }
        do {
            let denied = try PersistenceController(
                configuration: .local(storeURL: url),
                permissionPolicy: DenyPersistencePermissionPolicy()
            )
            XCTAssertThrowsError(
                try NeedService(persistence: denied).rememberOneTimeGroceryCreatingItem(
                    needID: needID, householdID: ids.householdID, listID: ids.listID,
                    catalog: catalog("Tea catalog", notes: "Catalog"),
                    need: RememberedNeedValues(
                        quantity: 5, purchaseNotes: "Changed", urgency: .urgent)
                ))
        }
        let reopened = try PersistenceController(storeURL: url)
        XCTAssertEqual(try snapshot(needID, reopened), before)
        XCTAssertTrue(
            try NeedService(persistence: reopened).allCatalogItemIDs(householdID: ids.householdID)
                .isEmpty
        )
    }

    func testSQLiteRelaunchPreservesUUIDCartedDraftAndCatalogRules() throws {
        let url = temporaryStoreURL()
        var ids: (householdID: UUID, listID: UUID)!
        var needID: UUID!
        var itemID: UUID!
        var storeID: UUID!
        var categoryID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: persistence)
            ids = try service.createHousehold()
            storeID = try service.createStore(name: "Costco", householdID: ids.householdID)
            categoryID = try service.createCategory(name: "Beverages", householdID: ids.householdID)
            needID = try service.addOneTimeNeed(title: "Coffee", notes: "Old", listID: ids.listID)
            try service.setCarted(true, needID: needID)
            itemID = try service.rememberOneTimeGroceryCreatingItem(
                needID: needID, householdID: ids.householdID, listID: ids.listID,
                catalog: CatalogItemValues(
                    name: "Coffee", notes: "Catalog beans", categoryID: categoryID,
                    anyStore: false, storeIDs: [storeID]
                ),
                need: RememberedNeedValues(
                    quantity: 6, purchaseNotes: "Current decaf", urgency: .urgent)
            )
        }
        let reopened = try PersistenceController(storeURL: url)
        let value = try snapshot(needID, reopened)
        XCTAssertEqual(value.id, needID)
        XCTAssertEqual(value.itemID, itemID)
        XCTAssertEqual(value.quantity, 6)
        XCTAssertTrue(value.carted)
        XCTAssertEqual(value.notes, "Current decaf")
        XCTAssertEqual(value.urgency, .urgent)
        XCTAssertEqual(value.itemNotes, "Catalog beans")
        XCTAssertEqual(value.itemCategoryID, categoryID)
        XCTAssertEqual(value.itemStoreIDs, [storeID])
        XCTAssertFalse(value.itemAnyStore)
    }

    func testLegacyWrappersRetainNeedValuesAndRejectOverflow() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let itemID = try service.createItem(
            name: "Tea", notes: "Catalog", householdID: ids.householdID)
        let linkID = try service.addOneTimeNeed(
            title: "Tea copy", notes: "Need", quantity: 4, urgency: .urgent, listID: ids.listID
        )
        XCTAssertEqual(
            try service.rememberOneTimeNeed(needID: linkID, existingItemID: itemID), itemID)
        let linked = try snapshot(linkID, persistence)
        XCTAssertEqual(linked.quantity, 4)
        XCTAssertEqual(linked.notes, "Need")
        XCTAssertEqual(linked.urgency, .urgent)

        let overflowLinkID = try service.addOneTimeNeed(
            title: "Overflow link", notes: "Keep", listID: ids.listID)
        let overflowItemID = try service.createItem(name: "Other tea", householdID: ids.householdID)
        try mutateNeed(overflowLinkID, persistence: persistence) { $0.revision = .max }
        let overflowLinkBefore = try snapshot(overflowLinkID, persistence)
        assertError(.scopeChanged) {
            try service.rememberOneTimeNeed(needID: overflowLinkID, existingItemID: overflowItemID)
        }
        XCTAssertEqual(try snapshot(overflowLinkID, persistence), overflowLinkBefore)

        let overflowID = try service.addOneTimeNeed(title: "New", notes: "Keep", listID: ids.listID)
        try mutateNeed(overflowID, persistence: persistence) { $0.revision = .max }
        let before = try snapshot(overflowID, persistence)
        assertError(.scopeChanged) {
            try service.rememberOneTimeNeedCreatingItem(needID: overflowID, itemNotes: "Catalog")
        }
        XCTAssertEqual(try snapshot(overflowID, persistence), before)
        XCTAssertEqual(
            Set(try service.allCatalogItemIDs(householdID: ids.householdID)),
            [itemID, overflowItemID])
    }

    private struct Snapshot: Equatable {
        let id: UUID
        let itemID: UUID?
        let kind: NeedKind
        let title: String
        let quantity: Int64
        let notes: String
        let urgency: NeedUrgency
        let carted: Bool
        let revision: Int64
        let clearOperationID: UUID?
        let itemNotes: String?
        let itemAnyStore: Bool
        let itemCategoryID: UUID?
        let itemStoreIDs: Set<UUID>
        let oneTimeCategoryID: UUID?
        let oneTimeStoreIDs: Set<UUID>
    }

    private func snapshot(_ id: UUID, _ persistence: PersistenceController) throws -> Snapshot {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let need = try XCTUnwrap(context.fetch(request).first)
            return Snapshot(
                id: need.id, itemID: need.item?.id, kind: NeedKind(rawValue: need.kind) ?? .oneTime,
                title: need.title, quantity: need.quantity, notes: need.notes,
                urgency: NeedUrgency(rawValue: need.urgency) ?? .normal, carted: need.carted,
                revision: need.revision, clearOperationID: need.clearOperationID,
                itemNotes: need.item?.notes,
                itemAnyStore: need.item?.anyStore ?? false, itemCategoryID: need.item?.category?.id,
                itemStoreIDs: Set(need.item?.stores?.map(\.id) ?? []),
                oneTimeCategoryID: need.oneTimeCategory?.id,
                oneTimeStoreIDs: Set(need.oneTimeStores?.map(\.id) ?? [])
            )
        }
    }

    private func catalog(_ name: String, notes: String = "") -> CatalogItemValues {
        CatalogItemValues(name: name, notes: notes, categoryID: nil, anyStore: true, storeIDs: [])
    }

    private func assertError<T>(_ expected: NeedServiceError, _ body: () throws -> T) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? NeedServiceError, expected) }
    }

    private func mutateNeed(
        _ id: UUID, persistence: PersistenceController, mutation: (Need) -> Void
    )
        throws
    {
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            mutation(try XCTUnwrap(context.fetch(request).first))
            try context.save()
        }
    }

    private func insertRemembered(itemID: UUID, listID: UUID, persistence: PersistenceController)
        throws
    {
        let context = persistence.simulationContext()
        try context.performAndWait {
            let itemRequest = Item.fetchRequest()
            itemRequest.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            let listRequest = GroceryList.fetchRequest()
            listRequest.predicate = NSPredicate(format: "id == %@", listID as CVarArg)
            let need =
                NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as! Need
            need.id = UUID()
            need.kind = NeedKind.remembered.rawValue
            need.title = "Duplicate"
            need.notes = ""
            need.quantity = 1
            need.carted = false
            need.urgency = NeedUrgency.normal.rawValue
            need.revision = 0
            need.archived = false
            need.oneTimeAnyStore = false
            need.item = try XCTUnwrap(context.fetch(itemRequest).first)
            need.list = try XCTUnwrap(context.fetch(listRequest).first)
            try context.save()
        }
    }

    private func duplicateItem(_ id: UUID, persistence: PersistenceController) throws {
        let context = persistence.simulationContext()
        try context.performAndWait {
            let item =
                NSEntityDescription.insertNewObject(forEntityName: "Item", into: context) as! Item
            item.id = id
            item.name = "Duplicate"
            item.notes = ""
            item.anyStore = true
            item.isArchived = false
            try context.save()
        }
    }

    private func insertDuplicate(_ entity: String, id: UUID, persistence: PersistenceController)
        throws
    {
        let context = persistence.simulationContext()
        try context.performAndWait {
            let object =
                NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
                as! IdentifiedManagedObject
            object.id = id
            if let household = object as? Household { household.name = "Duplicate" }
            if let need = object as? Need {
                need.kind = NeedKind.oneTime.rawValue
                need.title = "Duplicate"
                need.notes = ""
                need.quantity = 1
                need.carted = false
                need.urgency = NeedUrgency.normal.rawValue
                need.revision = 0
                need.archived = false
                need.oneTimeAnyStore = true
            }
            try context.save()
        }
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ShoppingPromotion-\(UUID().uuidString).sqlite")
    }
}
