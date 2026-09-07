import CoreData
import XCTest
@testable import Shopping

final class GroceryEditingTests: XCTestCase {
    func testCreateRememberedGrocerySavesCatalogAndNeedTogetherThenCompositeEditPreservesCarted() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let costco = try service.createStore(name: "Costco", householdID: selection.householdID)
        let category = try service.createCategory(name: "Pantry", householdID: selection.householdID)
        let created = try service.createRememberedGrocery(
            householdID: selection.householdID,
            listID: selection.listID,
            catalog: CatalogItemValues(
                name: " Rice ", notes: "Long grain", categoryID: category,
                anyStore: false, storeIDs: [costco]
            ),
            need: RememberedNeedValues(quantity: 3, purchaseNotes: "Two bags", urgency: .urgent)
        )
        try service.setCarted(true, needID: created.needID)
        try service.saveRememberedGrocery(
            needID: created.needID,
            householdID: selection.householdID,
            listID: selection.listID,
            catalog: CatalogItemValues(
                name: "  Brown rice \n", notes: " \n Whole grain \t", categoryID: nil,
                anyStore: true, storeIDs: [costco]
            ),
            need: RememberedNeedValues(quantity: 4, purchaseNotes: " \n One bag \t", urgency: .normal)
        )

        let state = try snapshot(created.needID, persistence: persistence)
        XCTAssertEqual(state.itemID, created.itemID)
        XCTAssertEqual(state.title, "Brown rice")
        XCTAssertEqual(state.quantity, 4)
        XCTAssertEqual(state.notes, "One bag")
        XCTAssertEqual(state.urgency, .normal)
        XCTAssertTrue(state.carted)
        XCTAssertEqual(state.itemName, "Brown rice")
        XCTAssertEqual(state.itemNotes, "Whole grain")
        XCTAssertTrue(state.itemAnyStore)
        XCTAssertEqual(state.itemStoreIDs, [costco])
    }

    func testRejectedRememberedCreationLeavesNoPartialCatalogOrNeed() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let existing = try service.createItem(name: "Milk", householdID: selection.householdID)
        XCTAssertThrowsError(try service.createRememberedGrocery(
            householdID: selection.householdID,
            listID: selection.listID,
            catalog: CatalogItemValues(
                name: " milk ", notes: "", categoryID: nil, anyStore: true, storeIDs: []
            )
        )) { XCTAssertEqual($0 as? NeedServiceError, .catalogNameCollision([existing])) }
        XCTAssertEqual(try service.allCatalogItemIDs(householdID: selection.householdID), [existing])
        XCTAssertTrue(try service.allActiveNeedIDs(householdID: selection.householdID).isEmpty)

        XCTAssertThrowsError(try service.createRememberedGrocery(
            householdID: selection.householdID,
            listID: selection.listID,
            catalog: CatalogItemValues(
                name: "Bread", notes: "", categoryID: nil, anyStore: true, storeIDs: []
            ),
            need: RememberedNeedValues(quantity: 100)
        )) { XCTAssertEqual($0 as? NeedServiceError, .invalidQuantity) }
        XCTAssertEqual(try service.allCatalogItemIDs(householdID: selection.householdID), [existing])
    }

    func testRememberedCreationPermissionAndPreSaveFailuresLeaveNoPairAfterReopen() throws {
        for failure in CreationSaveFailure.allCases {
            let url = temporaryStoreURL()
            var selection: (householdID: UUID, listID: UUID)!
            do {
                let persistence = try PersistenceController(storeURL: url)
                selection = try NeedService(persistence: persistence).createHousehold()
            }

            do {
                let failingPersistence: PersistenceController
                switch failure {
                case .permission:
                    failingPersistence = try PersistenceController(
                        configuration: .local(storeURL: url),
                        permissionPolicy: DenyPersistencePermissionPolicy()
                    )
                case .preSave:
                    failingPersistence = try PersistenceController(
                        configuration: .local(storeURL: url),
                        shareAssociationJournal: GroceryCreationThrowingJournal()
                    )
                }
                XCTAssertThrowsError(try NeedService(persistence: failingPersistence).createRememberedGrocery(
                    householdID: selection.householdID,
                    listID: selection.listID,
                    catalog: CatalogItemValues(
                        name: "Tea", notes: "Loose leaf", categoryID: nil,
                        anyStore: true, storeIDs: []
                    ),
                    need: RememberedNeedValues(quantity: 2, purchaseNotes: "Green", urgency: .urgent)
                ), "\(failure) must fail after the command stages its pair")
            }

            let reopened = try PersistenceController(storeURL: url)
            let reopenedService = NeedService(persistence: reopened)
            XCTAssertTrue(
                try reopenedService.allCatalogItemIDs(householdID: selection.householdID).isEmpty,
                "\(failure) must not persist the staged catalog item"
            )
            XCTAssertTrue(
                try reopenedService.allActiveNeedIDs(householdID: selection.householdID).isEmpty,
                "\(failure) must not persist the staged need"
            )
        }
    }

    func testExplicitNormalizedNameVariantCreatesSeparateLinkedCatalogAndNeed() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let original = try service.createItem(name: "Sparkling Water", householdID: selection.householdID)

        let created = try service.createRememberedGrocery(
            householdID: selection.householdID,
            listID: selection.listID,
            catalog: CatalogItemValues(
                name: "  sparkling   water ", notes: "Lime", categoryID: nil,
                anyStore: true, storeIDs: []
            ),
            allowingCatalogNameCollision: true
        )

        XCTAssertNotEqual(created.itemID, original)
        XCTAssertEqual(try service.allCatalogItemIDs(householdID: selection.householdID), [original, created.itemID])
        XCTAssertEqual(try snapshot(created.needID, persistence: persistence).itemID, created.itemID)
    }

    func testOneTimeCompositeEditChangesOwnValuesWithoutCreatingCatalogItem() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let store = try service.createStore(name: "Publix", householdID: selection.householdID)
        let category = try service.createCategory(name: "Party", householdID: selection.householdID)
        let needID = try service.addOneTimeNeed(title: "Ice", listID: selection.listID)
        try service.setCarted(true, needID: needID)

        try service.saveOneTimeGrocery(
            needID: needID,
            householdID: selection.householdID,
            listID: selection.listID,
            title: "Party ice",
            categoryID: category,
            storeIDs: [store],
            anyStore: false,
            need: RememberedNeedValues(quantity: 2, purchaseNotes: "Two bags", urgency: .urgent)
        )
        let state = try snapshot(needID, persistence: persistence)
        XCTAssertNil(state.itemID)
        XCTAssertEqual(state.title, "Party ice")
        XCTAssertEqual(state.quantity, 2)
        XCTAssertEqual(state.notes, "Two bags")
        XCTAssertEqual(state.urgency, .urgent)
        XCTAssertTrue(state.carted)
        XCTAssertEqual(state.oneTimeCategoryID, category)
        XCTAssertEqual(state.oneTimeStoreIDs, [store])
        XCTAssertTrue(try service.allCatalogItemIDs(householdID: selection.householdID).isEmpty)
    }

    func testDeniedCompositeSaveRollsBackCatalogAndNeedTogether() throws {
        let url = temporaryStoreURL()
        var selection: (householdID: UUID, listID: UUID)!
        var created: CreatedRememberedGrocery!
        var before: NeedSnapshot!
        do {
            let persistence = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: persistence)
            selection = try service.createHousehold()
            created = try service.createRememberedGrocery(
                householdID: selection.householdID,
                listID: selection.listID,
                catalog: CatalogItemValues(
                    name: "Coffee", notes: "Whole bean", categoryID: nil,
                    anyStore: true, storeIDs: []
                ),
                need: RememberedNeedValues(quantity: 2, purchaseNotes: "Dark roast", urgency: .urgent)
            )
            before = try snapshot(created.needID, persistence: persistence)
        }

        let denied = try PersistenceController(
            configuration: .local(storeURL: url),
            permissionPolicy: DenyPersistencePermissionPolicy()
        )
        let deniedService = NeedService(persistence: denied)
        XCTAssertThrowsError(try deniedService.saveRememberedGrocery(
            needID: created.needID,
            householdID: selection.householdID,
            listID: selection.listID,
            catalog: CatalogItemValues(
                name: "Espresso", notes: "Fine grind", categoryID: nil,
                anyStore: true, storeIDs: []
            ),
            need: RememberedNeedValues(quantity: 5, purchaseNotes: "Changed", urgency: .normal)
        ))

        let reopened = try PersistenceController(storeURL: url)
        XCTAssertEqual(try snapshot(created.needID, persistence: reopened), before)
    }

    func testCompositeEditRejectsForeignPurchaseRulesWithoutChangingNeed() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selected = try service.createHousehold()
        let foreign = try service.createHousehold()
        let foreignStore = try service.createStore(name: "Foreign store", householdID: foreign.householdID)
        let needID = try service.addOneTimeNeed(
            title: "Flowers",
            householdID: selected.householdID,
            listID: selected.listID
        )
        let before = try snapshot(needID, persistence: persistence)

        XCTAssertThrowsError(try service.saveOneTimeGrocery(
            needID: needID,
            householdID: selected.householdID,
            listID: selected.listID,
            title: "Bouquet",
            categoryID: nil,
            storeIDs: [foreignStore],
            anyStore: false,
            need: RememberedNeedValues(quantity: 2, purchaseNotes: "Red", urgency: .urgent)
        )) { XCTAssertEqual($0 as? NeedServiceError, .scopeChanged) }
        XCTAssertEqual(try snapshot(needID, persistence: persistence), before)
    }

    func testRememberedEditRejectsZeroAndDuplicateCatalogIdentityWithoutMutation() throws {
        for malformedIdentity in ["zero", "duplicate"] {
            let persistence = try makePersistence()
            let service = NeedService(persistence: persistence)
            let selection = try service.createHousehold()
            let itemID = try service.createItem(name: "Original", householdID: selection.householdID)
            let needID = try service.addRememberedNeed(itemID: itemID, listID: selection.listID)
            let otherID = try service.createItem(name: "Other", householdID: selection.householdID)
            let context = persistence.simulationContext()
            try context.performAndWait {
                let request = Item.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", (malformedIdentity == "zero" ? itemID : otherID) as CVarArg)
                let item = try XCTUnwrap(context.fetch(request).first)
                item.id = malformedIdentity == "zero" ? PersistenceModel.unsetID : itemID
                try context.save()
            }
            let before = try snapshot(needID, persistence: persistence)

            XCTAssertThrowsError(try service.saveRememberedGrocery(
                needID: needID,
                householdID: selection.householdID,
                listID: selection.listID,
                catalog: CatalogItemValues(
                    name: "Changed", notes: "Changed", categoryID: nil,
                    anyStore: true, storeIDs: []
                ),
                need: RememberedNeedValues(quantity: 4, purchaseNotes: "Changed", urgency: .urgent)
            )) { XCTAssertEqual($0 as? NeedServiceError, .invalidCatalogIdentity) }
            XCTAssertEqual(try snapshot(needID, persistence: persistence), before)
        }
    }

    func testRevisionExhaustionRejectsEditAndRemovalWithoutPartialRecoveryData() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let needID = try service.addOneTimeNeed(
            title: "Matches", householdID: selection.householdID, listID: selection.listID
        )
        try setRevision(Int64.max, needID: needID, persistence: persistence)
        let beforeEdit = try snapshot(needID, persistence: persistence)
        XCTAssertThrowsError(try service.saveOneTimeGrocery(
            needID: needID,
            householdID: selection.householdID,
            listID: selection.listID,
            title: "Changed",
            categoryID: nil,
            storeIDs: [],
            anyStore: true,
            need: RememberedNeedValues(quantity: 2)
        )) { XCTAssertEqual($0 as? NeedServiceError, .scopeChanged) }
        XCTAssertEqual(try snapshot(needID, persistence: persistence), beforeEdit)

        try setRevision(Int64.max - 1, needID: needID, persistence: persistence)
        let operationsBefore = try clearOperationCount(persistence: persistence)
        XCTAssertThrowsError(try service.removeNeed(
            needID: needID,
            householdID: selection.householdID,
            listID: selection.listID,
            expectedRevision: Int64.max - 1
        )) { XCTAssertEqual($0 as? NeedServiceError, .scopeChanged) }
        XCTAssertFalse(try snapshot(needID, persistence: persistence).archived)
        XCTAssertEqual(try clearOperationCount(persistence: persistence), operationsBefore)
    }

    func testRememberedNeedAgainRejectsRevisionOverflowBeforeResettingValues() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let itemID = try service.createItem(name: "Oats", householdID: selection.householdID)
        let needID = try service.addRememberedNeed(
            itemID: itemID, listID: selection.listID, quantity: 3, notes: "Old note", urgency: .urgent
        )
        try service.setCarted(true, needID: needID)
        try setRevision(Int64.max, needID: needID, persistence: persistence)
        let before = try snapshot(needID, persistence: persistence)

        XCTAssertThrowsError(try service.addRememberedNeed(
            itemID: itemID,
            listID: selection.listID,
            householdID: selection.householdID,
            quantity: 1,
            notes: "Changed",
            urgency: .normal
        )) { XCTAssertEqual($0 as? NeedServiceError, .scopeChanged) }
        XCTAssertEqual(try snapshot(needID, persistence: persistence), before)
    }

    func testScopedOneTimeUncartPreservesDraftValuesAndCatalogIsolation() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selected = try service.createHousehold()
        let foreign = try service.createHousehold()
        let storeID = try service.createStore(name: "Costco", householdID: selected.householdID)
        let needID = try service.addOneTimeNeed(
            title: "Napkins",
            notes: "Blue",
            storeIDs: [storeID],
            anyStore: false,
            quantity: 4,
            urgency: .urgent,
            householdID: selected.householdID,
            listID: selected.listID
        )
        try service.setCarted(true, needID: needID)
        let before = try snapshot(needID, persistence: persistence)

        XCTAssertThrowsError(try service.uncartNeed(
            needID: needID, householdID: foreign.householdID, listID: foreign.listID
        )) { XCTAssertEqual($0 as? NeedServiceError, .scopeChanged) }
        XCTAssertEqual(try snapshot(needID, persistence: persistence), before)

        try service.uncartNeed(
            needID: needID, householdID: selected.householdID, listID: selected.listID
        )
        let after = try snapshot(needID, persistence: persistence)
        XCTAssertFalse(after.carted)
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.quantity, before.quantity)
        XCTAssertEqual(after.notes, before.notes)
        XCTAssertEqual(after.urgency, before.urgency)
        XCTAssertEqual(after.oneTimeStoreIDs, before.oneTimeStoreIDs)
        XCTAssertEqual(after.revision, before.revision + 1)
        XCTAssertTrue(try service.allCatalogItemIDs(householdID: selected.householdID).isEmpty)
    }

    func testUndoSafelySkipsImportedRevisionThatCannotAdvance() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let needID = try service.addOneTimeNeed(
            title: "Imported", householdID: selection.householdID, listID: selection.listID
        )
        let operationID = try service.removeNeed(
            needID: needID,
            householdID: selection.householdID,
            listID: selection.listID,
            expectedRevision: try snapshot(needID, persistence: persistence).revision
        )
        let context = persistence.simulationContext()
        try context.performAndWait {
            let needRequest = Need.fetchRequest()
            needRequest.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let importedNeed = try XCTUnwrap(context.fetch(needRequest).first)
            importedNeed.revision = Int64.max
            let operationRequest = ClearOperation.fetchRequest()
            operationRequest.predicate = NSPredicate(format: "id == %@", operationID as CVarArg)
            let operation = try XCTUnwrap(context.fetch(operationRequest).first)
            operation.snapshot = try JSONEncoder().encode(ClearCartedToken(
                id: operationID,
                householdID: selection.householdID,
                listID: selection.listID,
                revisionsByNeedID: [needID: Int64.max]
            ))
            try context.save()
        }

        XCTAssertEqual(try service.undoClear(operationID: operationID), 0)
        let unchanged = try snapshot(needID, persistence: persistence)
        XCTAssertTrue(unchanged.archived)
        XCTAssertEqual(unchanged.revision, Int64.max)
    }

    func testIndividualRemovalSurvivesRelaunchAndUndoPreservesCartedValue() throws {
        let url = temporaryStoreURL()
        var selection: (householdID: UUID, listID: UUID)!
        var needID: UUID!, operationID: UUID!
        do {
            let persistence = try PersistenceController(storeURL: url)
            let service = NeedService(persistence: persistence)
            selection = try service.createHousehold()
            needID = try service.addOneTimeNeed(title: "Batteries", quantity: 2, listID: selection.listID)
            let revision = try snapshot(needID, persistence: persistence).revision
            operationID = try service.removeNeed(
                needID: needID,
                householdID: selection.householdID,
                listID: selection.listID,
                expectedRevision: revision
            )
            XCTAssertTrue(try snapshot(needID, persistence: persistence).archived)
        }

        let reopened = try PersistenceController(storeURL: url)
        let service = NeedService(persistence: reopened)
        XCTAssertEqual(try service.undoClear(
            operationID: operationID,
            expectedHouseholdID: selection.householdID,
            expectedListID: selection.listID
        ), 1)
        let restored = try snapshot(needID, persistence: reopened)
        XCTAssertFalse(restored.archived)
        XCTAssertFalse(restored.carted)
        XCTAssertEqual(restored.quantity, 2)
        XCTAssertNil(restored.itemID)
        XCTAssertTrue(try service.allCatalogItemIDs(householdID: selection.householdID).isEmpty)
    }

    func testStaleRemovalRejectsWithoutOperationAndRenewedRememberedNeedBlocksUndoDuplicate() throws {
        let persistence = try makePersistence()
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let item = try service.createItem(name: "Bread", householdID: selection.householdID)
        let original = try service.addRememberedNeed(itemID: item, listID: selection.listID)
        let captured = try snapshot(original, persistence: persistence).revision
        try service.setQuantity(2, needID: original)
        XCTAssertThrowsError(try service.removeNeed(
            needID: original,
            householdID: selection.householdID,
            listID: selection.listID,
            expectedRevision: captured
        )) { XCTAssertEqual($0 as? NeedServiceError, .scopeChanged) }
        XCTAssertFalse(try snapshot(original, persistence: persistence).archived)

        let revision = try snapshot(original, persistence: persistence).revision
        let operation = try service.removeNeed(
            needID: original,
            householdID: selection.householdID,
            listID: selection.listID,
            expectedRevision: revision
        )
        let renewed = try service.addRememberedNeed(itemID: item, listID: selection.listID)
        XCTAssertNotEqual(renewed, original)
        XCTAssertEqual(try service.undoClear(operationID: operation), 0)
        XCTAssertTrue(try snapshot(original, persistence: persistence).archived)
        XCTAssertFalse(try snapshot(renewed, persistence: persistence).archived)
    }

    private struct NeedSnapshot: Equatable {
        let itemID: UUID?
        let title: String
        let quantity: Int64?
        let notes: String
        let urgency: NeedUrgency
        let carted: Bool
        let archived: Bool
        let revision: Int64
        let itemName: String?
        let itemNotes: String?
        let itemAnyStore: Bool
        let itemStoreIDs: Set<UUID>
        let oneTimeCategoryID: UUID?
        let oneTimeStoreIDs: Set<UUID>
    }

    private func snapshot(_ id: UUID, persistence: PersistenceController) throws -> NeedSnapshot {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let need = try XCTUnwrap(context.fetch(request).first)
            return NeedSnapshot(
                itemID: need.item?.id,
                title: need.title,
                quantity: need.quantity,
                notes: need.notes,
                urgency: NeedUrgency(rawValue: need.urgency) ?? .normal,
                carted: need.carted,
                archived: need.archived,
                revision: need.revision,
                itemName: need.item?.name,
                itemNotes: need.item?.notes,
                itemAnyStore: need.item?.anyStore ?? false,
                itemStoreIDs: Set(need.item?.stores?.map(\.id) ?? []),
                oneTimeCategoryID: need.oneTimeCategory?.id,
                oneTimeStoreIDs: Set(need.oneTimeStores?.map(\.id) ?? [])
            )
        }
    }

    private func setRevision(_ revision: Int64, needID: UUID, persistence: PersistenceController) throws {
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let need = try XCTUnwrap(context.fetch(request).first)
            need.revision = revision
            try context.save()
        }
    }

    private func clearOperationCount(persistence: PersistenceController) throws -> Int {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "ClearOperation"))
        }
    }

    private func makePersistence() throws -> PersistenceController {
        try PersistenceController(storeURL: temporaryStoreURL())
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingGroceryEditingTests-\(UUID().uuidString).sqlite")
    }
}

private enum CreationSaveFailure: CaseIterable, CustomStringConvertible {
    case permission
    case preSave

    var description: String {
        switch self {
        case .permission: return "permission denial"
        case .preSave: return "pre-save journal failure"
        }
    }
}

private final class GroceryCreationThrowingJournal: ShareAssociationJournal {
    func stagePrivateInserts(_ objects: Set<NSManagedObject>, controller: PersistenceController) throws {
        throw CocoaError(.fileWriteUnknown)
    }

    func pending() throws -> [PendingShareAssociation] { [] }

    func acknowledge(householdURI: URL, objectURIs: Set<URL>) throws {}
}
