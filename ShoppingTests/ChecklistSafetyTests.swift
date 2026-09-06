import CoreData
import XCTest

@testable import Shopping

final class ChecklistSafetyTests: XCTestCase {
    func testCheckoutCapturesAllCartedRowsAndSkipsLaterChangesWithoutLosingCatalog() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let storeID = try service.createStore(name: "Market", householdID: selection.householdID)
        let categoryID = try service.createCategory(name: "Pantry", householdID: selection.householdID)
        let itemID = try service.createItem(
            name: "Rice", categoryID: categoryID, storeIDs: [storeID],
            householdID: selection.householdID, anyStore: false)
        let rememberedID = try service.addRememberedNeed(
            itemID: itemID, listID: selection.listID, householdID: selection.householdID)
        let oneTimeID = try service.addOneTimeNeed(
            title: "Ice", categoryID: categoryID, storeIDs: [storeID], anyStore: false,
            householdID: selection.householdID, listID: selection.listID)
        let addedAfterCaptureID = try service.addOneTimeNeed(
            title: "Flowers", anyStore: true,
            householdID: selection.householdID, listID: selection.listID)
        for id in [rememberedID, oneTimeID] {
            try service.setNeedCarted(
                needID: id, householdID: selection.householdID,
                listID: selection.listID, carted: true)
        }

        let preview = try service.prepareCheckout(
            householdID: selection.householdID, listID: selection.listID)
        XCTAssertEqual(Set(preview.rows.map(\.needID)), Set([rememberedID, oneTimeID]))
        XCTAssertEqual(preview.rows.filter(\.oneTime).map(\.needID), [oneTimeID])

        try service.setNeedQuantity(
            needID: oneTimeID, householdID: selection.householdID,
            listID: selection.listID, quantity: 4)
        try service.setNeedCarted(
            needID: addedAfterCaptureID, householdID: selection.householdID,
            listID: selection.listID, carted: true)

        XCTAssertEqual(try service.clearCarted(using: preview.token), 1)
        XCTAssertTrue(try archived(rememberedID, persistence))
        XCTAssertFalse(try archived(oneTimeID, persistence))
        XCTAssertFalse(try archived(addedAfterCaptureID, persistence))
        XCTAssertEqual(try needState(oneTimeID, persistence).quantity, 4)
        let catalog = try catalogState(itemID, persistence)
        XCTAssertEqual(catalog.name, "Rice")
        XCTAssertEqual(catalog.category, "Pantry")
        XCTAssertEqual(catalog.stores, Set(["Market"]))
        XCTAssertEqual(try itemCount(persistence), 1, "One-time checkout must not create catalog items")

        XCTAssertEqual(try service.undoClear(
            operationID: preview.token.id,
            expectedHouseholdID: selection.householdID,
            expectedListID: selection.listID), 1)
        XCTAssertFalse(try archived(rememberedID, persistence))
        XCTAssertEqual(try itemCount(persistence), 1)
    }

    func testPreparedClearUsesForcedCartedFilterAndDoesNotWrite() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let costco = try service.createStore(name: "Costco", householdID: selection.householdID)
        let publix = try service.createStore(name: "Publix", householdID: selection.householdID)
        let pantry = try service.createCategory(name: "Pantry", householdID: selection.householdID)
        let item = try service.createItem(
            name: "Granola", categoryID: pantry, storeIDs: [costco], householdID: selection.householdID,
            anyStore: false)
        let matching = try service.addRememberedNeed(
            itemID: item, listID: selection.listID, householdID: selection.householdID, quantity: 3,
            urgency: .urgent)
        let excluded = try service.addOneTimeNeed(
            title: "Granola excluded", categoryID: pantry, storeIDs: [costco, publix], anyStore: false,
            urgency: .urgent, listID: selection.listID)
        _ = try service.addOneTimeNeed(
            title: "Granola pending", categoryID: pantry, storeIDs: [costco], anyStore: false,
            urgency: .urgent, listID: selection.listID)
        let other = try service.addOneTimeNeed(
            title: "Other", storeIDs: [costco], anyStore: false, listID: selection.listID)
        try service.setNeedCarted(
            needID: matching, householdID: selection.householdID, listID: selection.listID, carted: true)
        try service.setNeedCarted(
            needID: other, householdID: selection.householdID, listID: selection.listID, carted: true)
        try service.setNeedCarted(
            needID: excluded, householdID: selection.householdID, listID: selection.listID, carted: true)
        let preview = try service.prepareClearCarted(
            householdID: selection.householdID, listID: selection.listID,
            filter: GroceryNeedFilter(
                purchase: PurchaseFilter(
                    selectedStoreID: costco, includedStoreIDs: [costco], excludedStoreIDs: [publix]), text: "gran",
                categoryID: pantry, carted: false, urgency: NeedUrgency.urgent.rawValue))
        XCTAssertEqual(preview.rows.map(\.needID), [matching])
        XCTAssertEqual(preview.rows.first?.title, "Granola")
        XCTAssertEqual(preview.rows.first?.quantity, 3)
        XCTAssertEqual(preview.rows.first?.revision, preview.token.revisionsByNeedID[matching])
        XCTAssertEqual(Set(preview.token.revisionsByNeedID.keys), [matching])
        XCTAssertEqual(try cartedIDs(persistence), Set([matching, other, excluded]))
        XCTAssertEqual(try clearOperationCount(persistence), 0)
    }

    func testScopedCartAndQuantityPreserveFieldsAndRejectForeignScope() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let other = try service.createHousehold()
        let id = try service.addOneTimeNeed(
            title: "Candles", notes: "40", quantity: 2, urgency: .urgent, householdID: selection.householdID,
            listID: selection.listID)
        try service.setNeedQuantity(
            needID: id, householdID: selection.householdID, listID: selection.listID, quantity: 5)
        try service.setNeedCarted(
            needID: id, householdID: selection.householdID, listID: selection.listID, carted: true)
        XCTAssertThrowsError(
            try service.setNeedCarted(
                needID: id, householdID: other.householdID, listID: other.listID, carted: false))
        let state = try needState(id, persistence)
        XCTAssertEqual(state.quantity, 5)
        XCTAssertEqual(state.notes, "40")
        XCTAssertEqual(state.urgency, NeedUrgency.urgent.rawValue)
        XCTAssertTrue(state.carted)
    }

    func testScopedCommandsRejectExhaustedRevisionWithoutChangingFields() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let id = try service.addOneTimeNeed(
            title: "Milk", quantity: 2, urgency: .urgent,
            householdID: selection.householdID, listID: selection.listID)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            try XCTUnwrap(context.fetch(request).first).revision = Int64.max
            try context.save()
        }
        XCTAssertThrowsError(try service.setNeedCarted(
            needID: id, householdID: selection.householdID, listID: selection.listID, carted: true))
        XCTAssertThrowsError(try service.setNeedQuantity(
            needID: id, householdID: selection.householdID, listID: selection.listID, quantity: 3))
        XCTAssertThrowsError(try service.setNeedQuantity(
            needID: id, householdID: selection.householdID, listID: selection.listID, quantity: 100)) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidQuantity)
        }
        let state = try needState(id, persistence)
        XCTAssertFalse(state.carted)
        XCTAssertEqual(state.quantity, 2)
        XCTAssertEqual(state.urgency, NeedUrgency.urgent.rawValue)
    }

    func testClearSkipsRevisionWithoutUndoHeadroomAndClearsOtherRows() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let exhausted = try service.addOneTimeNeed(
            title: "Old", householdID: selection.householdID, listID: selection.listID)
        let safe = try service.addOneTimeNeed(
            title: "Safe", householdID: selection.householdID, listID: selection.listID)
        try service.setNeedCarted(
            needID: exhausted, householdID: selection.householdID, listID: selection.listID, carted: true)
        try service.setNeedCarted(
            needID: safe, householdID: selection.householdID, listID: selection.listID, carted: true)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", exhausted as CVarArg)
            try XCTUnwrap(try context.fetch(request).first).revision = Int64.max - 1
            try context.save()
        }
        let token = try service.captureCarted(householdID: selection.householdID, listID: selection.listID)
        XCTAssertEqual(try service.clearCarted(using: token), 1)
        XCTAssertFalse(try archived(exhausted, persistence))
        XCTAssertTrue(try archived(safe, persistence))
    }

    func testPreviewRejectsDuplicateNeedIdentityBeforeProducingToken() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let id = try service.addOneTimeNeed(
            title: "Milk", householdID: selection.householdID, listID: selection.listID)
        try service.setNeedCarted(
            needID: id, householdID: selection.householdID, listID: selection.listID, carted: true)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let original = try XCTUnwrap(try context.fetch(request).first)
            let duplicate = NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as! Need
            duplicate.id = id
            duplicate.kind = original.kind
            duplicate.title = "Duplicate"
            duplicate.quantity = 1
            duplicate.notes = ""
            duplicate.urgency = NeedUrgency.normal.rawValue
            duplicate.revision = 0
            duplicate.carted = false
            duplicate.archived = false
            duplicate.oneTimeAnyStore = true
            duplicate.list = original.list
            try context.save()
        }
        XCTAssertThrowsError(
            try service.prepareClearCarted(
                householdID: selection.householdID, listID: selection.listID, filter: GroceryNeedFilter())
        ) { XCTAssertEqual($0 as? NeedServiceError, .invalidOccurrenceIdentity) }
    }

    func testPreviewRejectsForeignRelatedStore() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let foreign = try service.createHousehold()
        let item = try service.createItem(name: "Rice", householdID: selection.householdID, anyStore: true)
        let need = try service.addRememberedNeed(
            itemID: item, listID: selection.listID, householdID: selection.householdID)
        try service.setNeedCarted(
            needID: need, householdID: selection.householdID, listID: selection.listID, carted: true)
        let foreignStore = try service.createStore(name: "Foreign", householdID: foreign.householdID)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let itemRequest = Item.fetchRequest()
            itemRequest.predicate = NSPredicate(format: "id == %@", item as CVarArg)
            let storeRequest = Store.fetchRequest()
            storeRequest.predicate = NSPredicate(format: "id == %@", foreignStore as CVarArg)
            let object = try XCTUnwrap(try context.fetch(itemRequest).first)
            object.stores = [try XCTUnwrap(context.fetch(storeRequest).first)]
            try context.save()
        }
        XCTAssertThrowsError(
            try service.prepareClearCarted(
                householdID: selection.householdID, listID: selection.listID, filter: GroceryNeedFilter())
        ) { XCTAssertEqual($0 as? NeedServiceError, .invalidStoreIdentity) }
    }

    func testPreviewRejectsDuplicateRelatedItemIdentity() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let itemID = try service.createItem(name: "Rice", householdID: selection.householdID, anyStore: true)
        let needID = try service.addRememberedNeed(
            itemID: itemID, listID: selection.listID, householdID: selection.householdID)
        try service.setNeedCarted(
            needID: needID, householdID: selection.householdID, listID: selection.listID, carted: true)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            let original = try XCTUnwrap(try context.fetch(request).first)
            let duplicate = NSEntityDescription.insertNewObject(forEntityName: "Item", into: context) as! Item
            duplicate.id = itemID
            duplicate.name = "Duplicate"
            duplicate.notes = ""
            duplicate.anyStore = true
            duplicate.isArchived = false
            duplicate.household = original.household
            try context.save()
        }
        XCTAssertThrowsError(
            try service.prepareClearCarted(
                householdID: selection.householdID, listID: selection.listID, filter: GroceryNeedFilter())
        ) { XCTAssertEqual($0 as? NeedServiceError, .invalidCatalogIdentity) }
    }

    func testPreviewRejectsForeignRelatedCategory() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let foreign = try service.createHousehold()
        let needID = try service.addOneTimeNeed(
            title: "Candles", anyStore: true, householdID: selection.householdID, listID: selection.listID)
        try service.setNeedCarted(
            needID: needID, householdID: selection.householdID, listID: selection.listID, carted: true)
        let foreignCategory = try service.createCategory(name: "Foreign", householdID: foreign.householdID)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let needRequest = Need.fetchRequest()
            needRequest.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let categoryRequest = Category.fetchRequest()
            categoryRequest.predicate = NSPredicate(format: "id == %@", foreignCategory as CVarArg)
            try XCTUnwrap(try context.fetch(needRequest).first).oneTimeCategory = try XCTUnwrap(
                context.fetch(categoryRequest).first)
            try context.save()
        }
        XCTAssertThrowsError(
            try service.prepareClearCarted(
                householdID: selection.householdID, listID: selection.listID, filter: GroceryNeedFilter())
        ) { XCTAssertEqual($0 as? NeedServiceError, .categoryNotFound) }
    }

    private func makePersistence() throws -> PersistenceController {
        try PersistenceController(
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "ChecklistSafety-\(UUID().uuidString).sqlite"))
    }
    private func cartedIDs(_ p: PersistenceController) throws -> Set<UUID> {
        let c = p.simulationContext()
        return try c.performAndWait { Set(try c.fetch(Need.fetchRequest()).filter(\.carted).map(\.id)) }
    }
    private func needState(_ id: UUID, _ p: PersistenceController) throws -> (
        quantity: Int64?, notes: String, urgency: String, carted: Bool
    ) {
        let c = p.simulationContext()
        return try c.performAndWait {
            let r = Need.fetchRequest()
            r.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let n = try XCTUnwrap(try c.fetch(r).first)
            return (n.quantity, n.notes, n.urgency, n.carted)
        }
    }
    private func archived(_ id: UUID, _ p: PersistenceController) throws -> Bool {
        let c = p.simulationContext()
        return try c.performAndWait {
            let r = Need.fetchRequest()
            r.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return try XCTUnwrap(try c.fetch(r).first).archived
        }
    }
    private func clearOperationCount(_ p: PersistenceController) throws -> Int {
        let c = p.simulationContext()
        return try c.performAndWait {
            try c.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "ClearOperation"))
        }
    }
    private func itemCount(_ p: PersistenceController) throws -> Int {
        let c = p.simulationContext()
        return try c.performAndWait { try c.count(for: Item.fetchRequest()) }
    }
    private func catalogState(_ id: UUID, _ p: PersistenceController) throws -> (
        name: String, category: String?, stores: Set<String>
    ) {
        let c = p.simulationContext()
        return try c.performAndWait {
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let item = try XCTUnwrap(try c.fetch(request).first)
            return (item.name, item.category?.name, Set(item.stores?.map(\.name) ?? []))
        }
    }
}
