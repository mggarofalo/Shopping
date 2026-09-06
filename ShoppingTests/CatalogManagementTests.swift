import CoreData
import XCTest
@testable import Shopping

final class CatalogManagementTests: XCTestCase {
    func testAtomicCatalogSaveChangesMetadataAndRulesWithoutChangingNeedFieldsAfterReload() throws {
        let storeURL = temporaryStoreURL()
        var householdID: UUID!
        var itemID: UUID!
        var needID: UUID!
        var publixID: UUID!
        var categoryID: UUID!
        var expectedNeed: NeedSnapshot!

        do {
            let persistence = try PersistenceController(storeURL: storeURL)
            let service = NeedService(persistence: persistence)
            let selection = try service.createHousehold()
            householdID = selection.householdID
            let costcoID = try service.createStore(name: "Costco", householdID: householdID)
            publixID = try service.createStore(name: "Publix", householdID: householdID)
            categoryID = try service.createCategory(name: "Frozen", householdID: householdID)
            itemID = try service.createCatalogItem(
                values: CatalogItemValues(
                    name: "Strawberries",
                    notes: "Original note",
                    categoryID: nil,
                    anyStore: false,
                    storeIDs: [costcoID]
                ),
                householdID: householdID
            )
            needID = try service.addRememberedNeed(
                itemID: itemID,
                listID: selection.listID,
                quantity: 3,
                notes: "Buy two packs",
                urgency: .urgent
            )
            try service.setCarted(true, needID: needID)
            expectedNeed = try needSnapshot(needID, persistence: persistence)

            try service.saveCatalogItem(
                itemID: itemID,
                householdID: householdID,
                values: CatalogItemValues(
                    name: "Organic strawberries",
                    notes: "Frozen aisle",
                    categoryID: categoryID,
                    anyStore: false,
                    storeIDs: [publixID]
                )
            )
        }

        let reopened = try PersistenceController(storeURL: storeURL)
        XCTAssertEqual(
            try itemSnapshot(itemID, persistence: reopened),
            ItemSnapshot(
                id: itemID,
                name: "Organic strawberries",
                notes: "Frozen aisle",
                categoryID: categoryID,
                anyStore: false,
                storeIDs: [publixID],
                isArchived: false
            )
        )
        XCTAssertEqual(try needSnapshot(needID, persistence: reopened), expectedNeed)
        XCTAssertEqual(
            try NeedService(persistence: reopened).filteredCatalogItemIDs(
                householdID: householdID,
                filter: CatalogItemFilter(purchase: PurchaseFilter(selectedStoreID: publixID))
            ),
            [itemID]
        )
    }

    func testRejectedCatalogSaveLeavesItemAndNeedSnapshotsUntouchedAfterReload() throws {
        let storeURL = temporaryStoreURL()
        var householdID: UUID!
        var itemID: UUID!
        var itemBefore: ItemSnapshot!
        var needID: UUID!
        var needBefore: NeedSnapshot!

        do {
            let persistence = try PersistenceController(storeURL: storeURL)
            let service = NeedService(persistence: persistence)
            let local = try service.createHousehold()
            let foreign = try service.createHousehold()
            householdID = local.householdID
            let activeStore = try service.createStore(name: "Active", householdID: householdID)
            let archivedStore = try service.createStore(name: "Archived", householdID: householdID)
            try service.setStoreArchived(true, storeID: archivedStore, householdID: householdID)
            let foreignStore = try service.createStore(name: "Foreign", householdID: foreign.householdID)
            let foreignCategory = try service.createCategory(name: "Foreign", householdID: foreign.householdID)
            itemID = try service.createCatalogItem(
                values: CatalogItemValues(
                    name: "Olive oil",
                    notes: "Pantry",
                    categoryID: nil,
                    anyStore: false,
                    storeIDs: [activeStore]
                ),
                householdID: householdID
            )
            needID = try service.addRememberedNeed(itemID: itemID, listID: local.listID, quantity: 2, notes: "Cold pressed")
            itemBefore = try itemSnapshot(itemID, persistence: persistence)
            needBefore = try needSnapshot(needID, persistence: persistence)

            let invalidValues = [
                CatalogItemValues(name: " ", notes: "Changed", categoryID: nil, anyStore: true, storeIDs: []),
                CatalogItemValues(name: "Changed", notes: "Changed", categoryID: foreignCategory, anyStore: true, storeIDs: []),
                CatalogItemValues(name: "Changed", notes: "Changed", categoryID: nil, anyStore: false, storeIDs: [foreignStore]),
                CatalogItemValues(name: "Changed", notes: "Changed", categoryID: nil, anyStore: false, storeIDs: [archivedStore])
            ]
            for values in invalidValues {
                XCTAssertThrowsError(try service.saveCatalogItem(itemID: itemID, householdID: householdID, values: values))
            }
        }

        let reopened = try PersistenceController(storeURL: storeURL)
        XCTAssertEqual(try itemSnapshot(itemID, persistence: reopened), itemBefore)
        XCTAssertEqual(try needSnapshot(needID, persistence: reopened), needBefore)
    }

    func testPermissionAndPreSaveFailureRollBackCatalogSaveAfterReload() throws {
        for failure in SaveFailure.allCases {
            let storeURL = temporaryStoreURL()
            var householdID: UUID!
            var itemID: UUID!
            var itemBefore: ItemSnapshot!

            do {
                let persistence = try PersistenceController(storeURL: storeURL)
                let service = NeedService(persistence: persistence)
                let selection = try service.createHousehold()
                householdID = selection.householdID
                itemID = try service.createCatalogItem(
                    values: CatalogItemValues(
                        name: "Pasta",
                        notes: "Original",
                        categoryID: nil,
                        anyStore: true,
                        storeIDs: []
                    ),
                    householdID: householdID
                )
                itemBefore = try itemSnapshot(itemID, persistence: persistence)
            }

            do {
                let failingPersistence: PersistenceController
                switch failure {
                case .permission:
                    failingPersistence = try PersistenceController(
                        configuration: .local(storeURL: storeURL),
                        permissionPolicy: DenyPersistencePermissionPolicy()
                    )
                case .preSave:
                    failingPersistence = try PersistenceController(
                        configuration: .local(storeURL: storeURL),
                        shareAssociationJournal: ThrowingJournal()
                    )
                }
                let failingService = NeedService(persistence: failingPersistence)
                XCTAssertThrowsError(
                    try failingService.saveCatalogItem(
                        itemID: itemID,
                        householdID: householdID,
                        values: CatalogItemValues(
                            name: "Changed pasta",
                            notes: "Changed",
                            categoryID: nil,
                            anyStore: true,
                            storeIDs: []
                        )
                    )
                )
            }

            let reopened = try PersistenceController(storeURL: storeURL)
            XCTAssertEqual(try itemSnapshot(itemID, persistence: reopened), itemBefore, "\(failure) must roll back")
        }
    }

    func testCreateCatalogItemRequiresExplicitDistinctVariantIncludingArchivedMatch() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let values = CatalogItemValues(
            name: "  Sparkling   Water ",
            notes: "",
            categoryID: nil,
            anyStore: true,
            storeIDs: []
        )
        let originalID = try service.createCatalogItem(values: values, householdID: selection.householdID)

        XCTAssertThrowsError(try service.createCatalogItem(values: values, householdID: selection.householdID)) {
            XCTAssertEqual($0 as? NeedServiceError, .catalogNameCollision([originalID]))
        }
        try service.setCatalogItemArchived(itemID: originalID, householdID: selection.householdID, archived: true)
        XCTAssertThrowsError(try service.createCatalogItem(values: values, householdID: selection.householdID)) {
            XCTAssertEqual($0 as? NeedServiceError, .catalogNameCollision([originalID]))
        }

        let variantID = try service.createCatalogItem(
            values: values,
            householdID: selection.householdID,
            allowingNameCollision: true
        )
        XCTAssertNotEqual(variantID, originalID)
        XCTAssertEqual(
            try service.filteredCatalogItemIDs(householdID: selection.householdID, filter: CatalogItemFilter()),
            [variantID]
        )
        XCTAssertEqual(
            try service.filteredCatalogItemIDs(
                householdID: selection.householdID,
                filter: CatalogItemFilter(),
                includeArchived: true
            ).sorted { $0.uuidString < $1.uuidString },
            [originalID, variantID].sorted { $0.uuidString < $1.uuidString }
        )
    }

    func testSaveCatalogItemRenameCollisionRequiresExplicitVariantButAllowsUnchangedDuplicateName() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let duplicateValues = CatalogItemValues(
            name: "Sparkling Water",
            notes: "",
            categoryID: nil,
            anyStore: true,
            storeIDs: []
        )
        let firstID = try service.createCatalogItem(values: duplicateValues, householdID: selection.householdID)
        let duplicateID = try service.createCatalogItem(
            values: duplicateValues,
            householdID: selection.householdID,
            allowingNameCollision: true
        )
        let renamedID = try service.createCatalogItem(
            values: CatalogItemValues(
                name: "Tea",
                notes: "Original",
                categoryID: nil,
                anyStore: true,
                storeIDs: []
            ),
            householdID: selection.householdID
        )

        try service.saveCatalogItem(
            itemID: duplicateID,
            householdID: selection.householdID,
            values: CatalogItemValues(
                name: "  sparkling   water ",
                notes: "Updated duplicate",
                categoryID: nil,
                anyStore: true,
                storeIDs: []
            )
        )
        XCTAssertEqual(try itemSnapshot(duplicateID, persistence: persistence).notes, "Updated duplicate")

        let beforeRejectedRename = try itemSnapshot(renamedID, persistence: persistence)
        let collidingValues = CatalogItemValues(
            name: "SPARKLING WATER",
            notes: "Should not save",
            categoryID: nil,
            anyStore: true,
            storeIDs: []
        )
        XCTAssertThrowsError(
            try service.saveCatalogItem(
                itemID: renamedID,
                householdID: selection.householdID,
                values: collidingValues
            )
        ) {
            XCTAssertEqual(
                $0 as? NeedServiceError,
                .catalogNameCollision([firstID, duplicateID].sorted { $0.uuidString < $1.uuidString })
            )
        }
        XCTAssertEqual(try itemSnapshot(renamedID, persistence: persistence), beforeRejectedRename)

        try service.saveCatalogItem(
            itemID: renamedID,
            householdID: selection.householdID,
            values: collidingValues,
            allowingNameCollision: true
        )
        XCTAssertEqual(try itemSnapshot(renamedID, persistence: persistence).name, "SPARKLING WATER")
    }

    func testArchiveRestoreRetainsActiveNeedAndArchivedReadFilterIncludesCatalogItem() throws {
        let storeURL = temporaryStoreURL()
        var householdID: UUID!
        var itemID: UUID!
        var needID: UUID!
        var expectedNeed: NeedSnapshot!

        do {
            let persistence = try PersistenceController(storeURL: storeURL)
            let service = NeedService(persistence: persistence)
            let selection = try service.createHousehold()
            householdID = selection.householdID
            itemID = try service.createCatalogItem(
                values: CatalogItemValues(
                    name: "Coffee",
                    notes: "Whole bean",
                    categoryID: nil,
                    anyStore: true,
                    storeIDs: []
                ),
                householdID: householdID
            )
            needID = try service.addRememberedNeed(itemID: itemID, listID: selection.listID, quantity: 4, notes: "Decaf", urgency: .urgent)
            try service.setCarted(true, needID: needID)
            expectedNeed = try needSnapshot(needID, persistence: persistence)

            try service.setCatalogItemArchived(itemID: itemID, householdID: householdID, archived: true)
            XCTAssertEqual(try service.allActiveNeedIDs(householdID: householdID), [needID])
            XCTAssertEqual(try service.filteredCatalogItemIDs(householdID: householdID, filter: CatalogItemFilter()), [])
            XCTAssertEqual(
                try service.filteredCatalogItemIDs(
                    householdID: householdID,
                    filter: CatalogItemFilter(),
                    includeArchived: true
                ),
                [itemID]
            )
            try service.setCatalogItemArchived(itemID: itemID, householdID: householdID, archived: false)
        }

        let reopened = try PersistenceController(storeURL: storeURL)
        XCTAssertEqual(try itemSnapshot(itemID, persistence: reopened).isArchived, false)
        XCTAssertEqual(try needSnapshot(needID, persistence: reopened), expectedNeed)
        XCTAssertEqual(try NeedService(persistence: reopened).allActiveNeedIDs(householdID: householdID), [needID])
    }

    private enum SaveFailure: CaseIterable, CustomStringConvertible {
        case permission
        case preSave

        var description: String {
            switch self {
            case .permission: return "permission denial"
            case .preSave: return "pre-save journal failure"
            }
        }
    }

    private struct ItemSnapshot: Equatable {
        let id: UUID
        let name: String
        let notes: String
        let categoryID: UUID?
        let anyStore: Bool
        let storeIDs: Set<UUID>
        let isArchived: Bool
    }

    private struct NeedSnapshot: Equatable {
        let id: UUID
        let title: String
        let itemID: UUID?
        let quantity: Int64?
        let carted: Bool
        let urgency: String
        let notes: String
        let isArchived: Bool
        let revision: Int64
        let clearOperationID: UUID?
    }

    private func itemSnapshot(_ itemID: UUID, persistence: PersistenceController) throws -> ItemSnapshot {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            let item = try XCTUnwrap(context.fetch(request).first)
            return ItemSnapshot(
                id: item.id,
                name: item.name,
                notes: item.notes,
                categoryID: item.category?.id,
                anyStore: item.anyStore,
                storeIDs: Set(item.stores?.map(\.id) ?? []),
                isArchived: item.isArchived
            )
        }
    }

    private func needSnapshot(_ needID: UUID, persistence: PersistenceController) throws -> NeedSnapshot {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let need = try XCTUnwrap(context.fetch(request).first)
            return NeedSnapshot(
                id: need.id,
                title: need.title,
                itemID: need.item?.id,
                quantity: need.quantity,
                carted: need.carted,
                urgency: need.urgency,
                notes: need.notes,
                isArchived: need.archived,
                revision: need.revision,
                clearOperationID: need.clearOperationID
            )
        }
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingCatalogManagementTests-\(UUID().uuidString).sqlite")
    }
}

private final class ThrowingJournal: ShareAssociationJournal {
    func stagePrivateInserts(_ objects: Set<NSManagedObject>, controller: PersistenceController) throws {
        throw CocoaError(.fileWriteUnknown)
    }

    func pending() throws -> [PendingShareAssociation] { [] }

    func acknowledge(householdURI: URL, objectURIs: Set<URL>) throws {}
}
