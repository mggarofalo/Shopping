import CoreData
import XCTest
@testable import Shopping

final class GroceryNeedTests: XCTestCase {
    func testExplicitReaddReusesActiveOccurrenceAndResetsCartAndUrgency() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let itemID = try service.createItem(name: "Milk", householdID: ids.householdID)
        let needID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
        try service.setQuantity(7, needID: needID)
        try service.setPurchaseNote("Get lactose free", needID: needID)
        try service.setCarted(true, needID: needID)
        try service.setUrgency(.urgent, needID: needID)

        XCTAssertEqual(try service.activeRememberedNeedID(itemID: itemID, listID: ids.listID), needID)
        XCTAssertEqual(try state(needID, persistence: persistence).urgency, "urgent", "Lookup must not mutate urgency")
        XCTAssertEqual(try service.addRememberedNeed(itemID: itemID, listID: ids.listID), needID)

        let readded = try state(needID, persistence: persistence)
        XCTAssertEqual(readded.quantity, 7)
        XCTAssertEqual(readded.notes, "Get lactose free")
        XCTAssertFalse(readded.carted)
        XCTAssertEqual(readded.urgency, "normal")
    }

    func testReaddAfterClearCreatesNewOccurrenceAndStaleUndoCannotReplaceIt() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let itemID = try service.createItem(name: "Bread", householdID: ids.householdID)
        let oldID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
        try service.setCarted(true, needID: oldID)
        let token = try service.captureCarted(householdID: ids.householdID, listID: ids.listID)
        XCTAssertEqual(try service.clearCarted(using: token), 1)
        let newID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID, urgency: .urgent)

        XCTAssertNotEqual(oldID, newID)
        XCTAssertEqual(try service.undoClear(operationID: token.id), 0)
        XCTAssertTrue(try state(oldID, persistence: persistence).archived)
        XCTAssertFalse(try state(newID, persistence: persistence).archived)
    }

    func testOneTimeOwnRulesAndDataRoundTripWithoutCatalogLink() throws {
        let url = temporaryStoreURL()
        var householdID: UUID!, needID: UUID!, storeID: UUID!, categoryID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            householdID = ids.householdID
            storeID = try service.createStore(name: "Costco", householdID: householdID)
            categoryID = try service.createCategory(name: "Party", householdID: householdID)
            needID = try service.addOneTimeNeed(
                title: "  Party ice  ", notes: "Two bags", categoryID: categoryID,
                storeIDs: [storeID], anyStore: false, quantity: 2, urgency: .urgent, listID: ids.listID
            )
        }

        let relaunched = try PersistenceController(storeURL: url)
        let service = NeedService(persistence: relaunched)
        XCTAssertEqual(
            try service.filteredActiveNeedIDs(
                householdID: householdID,
                filter: GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: storeID), text: "party", categoryID: categoryID)
            ),
            [needID]
        )
        let context = relaunched.simulationContext()
        try context.performAndWait {
            let need = try self.fetchNeed(needID, context: context)
            XCTAssertNil(need.item)
            XCTAssertEqual(need.title, "Party ice")
            XCTAssertEqual(need.notes, "Two bags")
            XCTAssertEqual(need.quantity, 2)
            XCTAssertEqual(need.urgency, "urgent")
            XCTAssertEqual(need.oneTimeCategory?.id, categoryID)
            XCTAssertEqual(Set(need.oneTimeStores?.map(\.id) ?? []), [storeID])
            XCTAssertEqual(try context.count(for: Item.fetchRequest()), 0)
        }
    }

    func testOneTimeValidationIsAtomicAndQuantityIsLimitedToOneThroughNinetyNine() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let local = try service.createHousehold()
        let foreign = try service.createHousehold()
        let foreignStore = try service.createStore(name: "Foreign", householdID: foreign.householdID)
        let untagged = try service.addOneTimeNeed(title: "Ice", storeIDs: [], anyStore: false, listID: local.listID)
        XCTAssertThrowsError(try service.addOneTimeNeed(title: "Ice", storeIDs: [foreignStore], listID: local.listID))
        XCTAssertThrowsError(try service.addOneTimeNeed(title: "Ice", quantity: 100, listID: local.listID))
        XCTAssertEqual(try service.allActiveNeedIDs(householdID: local.householdID), [untagged])

        let valid = try service.addOneTimeNeed(title: "Ice", quantity: 99, listID: local.listID)
        XCTAssertThrowsError(try service.setQuantity(0, needID: valid))
        XCTAssertThrowsError(try service.setQuantity(100, needID: valid))
        XCTAssertEqual(try state(valid, persistence: persistence).quantity, 99)
    }

    func testCatalogCopyCreatesIndependentOneTimeNeedWithoutMutatingCatalog() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let storeID = try service.createStore(name: "Aldi", householdID: ids.householdID)
        let itemID = try service.createItem(
            name: "Coffee", notes: "Dark roast", storeIDs: [storeID],
            householdID: ids.householdID, anyStore: false
        )
        let needID = try service.copyCatalogItemAsOneTimeNeed(itemID: itemID, listID: ids.listID)
        try service.updateOneTimeNeed(
            needID: needID, title: "Decaf coffee", notes: "Guests", categoryID: nil,
            storeIDs: [storeID], anyStore: false
        )
        let context = persistence.simulationContext()
        try context.performAndWait {
            let need = try self.fetchNeed(needID, context: context)
            XCTAssertNil(need.item)
            XCTAssertEqual(need.kind, NeedKind.oneTime.rawValue)
            XCTAssertEqual(need.title, "Decaf coffee")
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            let item = try XCTUnwrap(context.fetch(request).first)
            XCTAssertEqual(item.name, "Coffee")
            XCTAssertEqual(item.notes, "Dark roast")
            XCTAssertEqual(Set(item.stores?.map(\.id) ?? []), [storeID])
        }
    }

    func testRememberRequiresExplicitMatchResolutionAndFailurePreservesOneTimeData() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let existingItem = try service.createItem(name: "Vanilla Ice Cream", householdID: ids.householdID)
        let oneTime = try service.addOneTimeNeed(title: " vanilla   ice cream ", notes: "For cake", listID: ids.listID)

        XCTAssertThrowsError(try service.rememberOneTimeNeedCreatingItem(needID: oneTime)) {
            XCTAssertEqual($0 as? NeedServiceError, .catalogNameCollision([existingItem]))
        }
        XCTAssertNil(try state(oneTime, persistence: persistence).itemID)
        XCTAssertEqual(try state(oneTime, persistence: persistence).notes, "For cake")
        XCTAssertEqual(try service.rememberOneTimeNeed(needID: oneTime, existingItemID: existingItem), existingItem)
        XCTAssertEqual(try state(oneTime, persistence: persistence).itemID, existingItem)
    }

    func testRememberConflictLeavesOneTimeIndependent() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let itemID = try service.createItem(name: "Rice", householdID: ids.householdID)
        let activeID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID)
        let oneTimeID = try service.addOneTimeNeed(title: "Rice", notes: "Special bag", listID: ids.listID)
        XCTAssertThrowsError(try service.rememberOneTimeNeed(needID: oneTimeID, existingItemID: itemID)) {
            XCTAssertEqual($0 as? NeedServiceError, .activeRememberedNeedConflict(activeID))
        }
        let unchanged = try state(oneTimeID, persistence: persistence)
        XCTAssertNil(unchanged.itemID)
        XCTAssertEqual(unchanged.notes, "Special bag")
    }

    func testCapturedSubsetClearsOnlyCapturedUnchangedOccurrences() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let first = try service.addOneTimeNeed(title: "First", listID: ids.listID)
        let second = try service.addOneTimeNeed(title: "Second", listID: ids.listID)
        try service.setCarted(true, needID: first)
        try service.setCarted(true, needID: second)
        let token = try service.captureCarted(householdID: ids.householdID, listID: ids.listID, restrictedToNeedIDs: [first])
        XCTAssertEqual(Set(token.revisionsByNeedID.keys), [first])
        XCTAssertEqual(try service.clearCarted(using: token), 1)
        XCTAssertTrue(try state(first, persistence: persistence).archived)
        XCTAssertFalse(try state(second, persistence: persistence).archived)
    }

    func testDuplicateDetectionPreservesDivergentRowsAcrossRelaunch() throws {
        let url = temporaryStoreURL()
        var householdID: UUID!, listID: UUID!, itemID: UUID!, originalID: UUID!, duplicateID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            householdID = ids.householdID; listID = ids.listID
            itemID = try service.createItem(name: "Beans", householdID: householdID)
            originalID = try service.addRememberedNeed(itemID: itemID, listID: listID, quantity: 2, urgency: .urgent)
            let context = persistence.simulationContext()
            try context.performAndWait {
                let original = try self.fetchNeed(originalID, context: context)
                let duplicate = try XCTUnwrap(
                    NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as? Need
                )
                duplicateID = UUID()
                duplicate.id = duplicateID
                duplicate.kind = NeedKind.remembered.rawValue
                duplicate.title = original.title
                duplicate.notes = "Replica edit"
                duplicate.quantity = 5
                duplicate.carted = true
                duplicate.urgency = NeedUrgency.normal.rawValue
                duplicate.revision = 9
                duplicate.archived = false
                duplicate.oneTimeAnyStore = false
                duplicate.list = original.list
                duplicate.item = original.item
                try context.save()
            }
        }

        let persistence = try PersistenceController(storeURL: url)
        let service = NeedService(persistence: persistence)
        let groups = try service.rememberedDuplicateGroups(householdID: householdID, listID: listID)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].itemID, itemID)
        XCTAssertEqual(groups[0].candidates.map(\.needID), [originalID!, duplicateID!].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(Set(groups[0].candidates.map(\.quantity)), [2, 5])
        XCTAssertEqual(Set(groups[0].candidates.map(\.notes)), ["", "Replica edit"])
        XCTAssertThrowsError(try service.addRememberedNeed(itemID: itemID, listID: listID)) {
            guard case .activeRememberedNeedDuplicates(let group) = $0 as? NeedServiceError else {
                return XCTFail("Expected typed duplicate group")
            }
            XCTAssertEqual(group, groups[0])
        }
        XCTAssertEqual(try service.rememberedDuplicateGroups(householdID: householdID, listID: listID), groups)
    }

    func testAmbiguousImportedOccurrenceIdentityFailsMutationAndActiveProjections() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let storeID = try service.createStore(name: "Costco", householdID: ids.householdID)
        let originalID = try service.addOneTimeNeed(title: "Imported", listID: ids.listID)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let original = try self.fetchNeed(originalID, context: context)
            original.kind = ""
            original.oneTimeAnyStore = true
            let duplicate = try XCTUnwrap(
                NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as? Need
            )
            duplicate.id = originalID
            duplicate.kind = ""
            duplicate.title = "Imported duplicate"
            duplicate.notes = ""
            duplicate.quantity = 1
            duplicate.carted = false
            duplicate.urgency = NeedUrgency.normal.rawValue
            duplicate.revision = 0
            duplicate.archived = false
            duplicate.oneTimeAnyStore = true
            duplicate.list = original.list
            try context.save()
        }

        XCTAssertThrowsError(try service.setCarted(true, needID: originalID)) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidOccurrenceIdentity)
        }
        XCTAssertThrowsError(try service.allActiveNeedIDs(householdID: ids.householdID)) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidOccurrenceIdentity)
        }
        XCTAssertThrowsError(
            try service.filteredActiveNeedIDs(
                householdID: ids.householdID,
                filter: GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: storeID))
            )
        ) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidOccurrenceIdentity)
        }
    }

    func testUnknownImportedLifecycleDoesNotUseOneTimeRules() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let storeID = try service.createStore(name: "Costco", householdID: ids.householdID)
        let needID = try service.addOneTimeNeed(title: "Imported", listID: ids.listID)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let need = try self.fetchNeed(needID, context: context)
            need.kind = ""
            need.oneTimeAnyStore = true
            try context.save()
        }
        XCTAssertEqual(
            try service.filteredActiveNeedIDs(
                householdID: ids.householdID,
                filter: GroceryNeedFilter(purchase: PurchaseFilter(selectedStoreID: storeID))
            ),
            []
        )
    }

    func testInvalidActiveRememberedIdentitiesFailClosedWithoutMutation() throws {
        for duplicateIdentity in [false, true] {
            let persistence = try makePersistence()
            let service = NeedService(persistence: persistence)
            let ids = try service.createHousehold()
            let itemID = try service.createItem(name: "Beans", householdID: ids.householdID)
            let needID = try service.addRememberedNeed(itemID: itemID, listID: ids.listID, quantity: 4)
            let context = persistence.simulationContext()
            try context.performAndWait {
                let original = try self.fetchNeed(needID, context: context)
                if duplicateIdentity {
                    let duplicate = try XCTUnwrap(
                        NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as? Need
                    )
                    duplicate.id = needID
                    duplicate.kind = NeedKind.remembered.rawValue
                    duplicate.title = "Beans"
                    duplicate.notes = "Replica"
                    duplicate.quantity = 8
                    duplicate.carted = false
                    duplicate.urgency = NeedUrgency.urgent.rawValue
                    duplicate.revision = 2
                    duplicate.archived = false
                    duplicate.oneTimeAnyStore = false
                    duplicate.list = original.list
                    duplicate.item = original.item
                } else {
                    original.id = PersistenceModel.unsetID
                }
                try context.save()
            }

            XCTAssertThrowsError(try service.addRememberedNeed(itemID: itemID, listID: ids.listID, quantity: 1)) {
                XCTAssertEqual($0 as? NeedServiceError, .invalidOccurrenceIdentity)
            }
            let verify = persistence.simulationContext()
            try verify.performAndWait {
                let request = Need.fetchRequest()
                request.predicate = NSPredicate(format: "item.id == %@ AND archived == NO", itemID as CVarArg)
                XCTAssertEqual(Set(try verify.fetch(request).map(\.quantity)), duplicateIdentity ? [4, 8] : [4])
            }
        }
    }

    func testRememberCreatingCatalogRejectsBlankImportedOneTimeTitleWithoutMutation() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let needID = try service.addOneTimeNeed(title: "Temporary", notes: "Keep me", listID: ids.listID)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let need = try self.fetchNeed(needID, context: context)
            need.title = " \n "
            try context.save()
        }

        XCTAssertThrowsError(try service.rememberOneTimeNeedCreatingItem(needID: needID)) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidName)
        }
        let unchanged = try state(needID, persistence: persistence)
        XCTAssertNil(unchanged.itemID)
        XCTAssertEqual(unchanged.notes, "Keep me")
        let verify = persistence.simulationContext()
        XCTAssertEqual(try verify.performAndWait { try verify.count(for: Item.fetchRequest()) }, 0)
    }

    private typealias State = (quantity: Int64?, carted: Bool, urgency: String, archived: Bool, notes: String, itemID: UUID?)

    private func state(_ id: UUID, persistence: PersistenceController) throws -> State {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let need = try fetchNeed(id, context: context)
            return (need.quantity, need.carted, need.urgency, need.archived, need.notes, need.item?.id)
        }
    }

    private func fetchNeed(_ id: UUID, context: NSManagedObjectContext) throws -> Need {
        let request = Need.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func makePersistence() throws -> PersistenceController {
        try PersistenceController(storeURL: temporaryStoreURL())
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingNeedTests-\(UUID().uuidString).sqlite")
    }
}
