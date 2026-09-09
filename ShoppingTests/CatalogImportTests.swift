import CoreData
import XCTest
@testable import Shopping

final class CatalogImportTests: XCTestCase {
    func testRepeatImportUpdatesStableItemWithoutCreatingDuplicate() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let categoryID = try service.createCategory(name: "Dairy", householdID: selection.householdID)
        let storeID = try service.createStore(name: "Publix", householdID: selection.householdID)
        let original = row(name: "Whole milk", notes: "2%", category: "Dairy", stores: ["Publix"])

        let firstPreview = try service.previewCatalogImport(
            rows: [original], householdID: selection.householdID, listID: selection.listID
        )
        XCTAssertEqual(firstPreview.entries.first?.disposition, .create)
        let itemID = try XCTUnwrap(firstPreview.entries.first?.catalogItemID)
        XCTAssertEqual(
            try service.applyCatalogImport(firstPreview, actions: [original.id: .create]),
            CatalogImportResult(created: 1, updated: 0, skipped: 0, changed: 0)
        )
        XCTAssertEqual(try itemCount(in: persistence), 1)
        XCTAssertEqual(try itemState(itemID, in: persistence).categoryID, categoryID)
        XCTAssertEqual(try itemState(itemID, in: persistence).storeIDs, [storeID])

        let changedRow = row(name: "Whole milk", notes: "Updated note", category: "Dairy", stores: ["Publix"])
        let repeatPreview = try service.previewCatalogImport(
            rows: [changedRow], householdID: selection.householdID, listID: selection.listID
        )
        XCTAssertEqual(repeatPreview.entries.first?.disposition, .update)
        XCTAssertEqual(
            try service.applyCatalogImport(repeatPreview, actions: [changedRow.id: .update]),
            CatalogImportResult(created: 0, updated: 1, skipped: 0, changed: 0)
        )
        XCTAssertEqual(try itemCount(in: persistence), 1)
        XCTAssertEqual(try itemState(itemID, in: persistence).notes, "Updated note")
    }

    func testNameConflictRequiresExplicitSeparateImportAndInvalidMappingStaysSkipped() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let originalID = try service.createCatalogItem(
            values: CatalogItemValues(name: "Milk", notes: "", categoryID: nil, anyStore: true, storeIDs: []),
            householdID: selection.householdID
        )
        let conflict = row(name: "Milk")
        let invalid = CatalogImportRow(
            line: 3, sourceID: "test", itemID: "2", name: "Bread", notes: "",
            categoryName: nil, storeNames: ["Missing store"]
        )
        let preview = try service.previewCatalogImport(
            rows: [conflict, invalid], householdID: selection.householdID, listID: selection.listID
        )

        XCTAssertEqual(preview.entries[0].disposition, .nameConflict([originalID]))
        if case .invalid(let reason) = preview.entries[1].disposition {
            XCTAssertTrue(reason.contains("Missing store"))
        } else {
            XCTFail("Expected the unresolved store to remain visible as invalid")
        }
        XCTAssertEqual(
            try service.applyCatalogImport(preview, actions: [conflict.id: .create, invalid.id: .create]),
            CatalogImportResult(created: 1, updated: 0, skipped: 1, changed: 0)
        )
        XCTAssertEqual(try itemCount(in: persistence), 2)
    }

    func testApplyDoesNotOverwriteItemChangedAfterPreview() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let imported = row(name: "Coffee", notes: "Imported")
        let createPreview = try service.previewCatalogImport(
            rows: [imported], householdID: selection.householdID, listID: selection.listID
        )
        _ = try service.applyCatalogImport(createPreview, actions: [imported.id: .create])
        let itemID = try XCTUnwrap(createPreview.entries.first?.catalogItemID)
        let updatePreview = try service.previewCatalogImport(
            rows: [row(name: "Coffee", notes: "New import")],
            householdID: selection.householdID,
            listID: selection.listID
        )
        try service.saveCatalogItem(
            itemID: itemID,
            householdID: selection.householdID,
            values: CatalogItemValues(name: "Coffee", notes: "Manual edit", categoryID: nil, anyStore: true, storeIDs: [])
        )

        XCTAssertEqual(
            try service.applyCatalogImport(updatePreview, actions: [imported.id: .update]),
            CatalogImportResult(created: 0, updated: 0, skipped: 0, changed: 1)
        )
        XCTAssertEqual(try itemState(itemID, in: persistence).notes, "Manual edit")
    }

    func testIncomingNameDuplicatesRequireExplicitSeparateImports() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let first = row(name: "Milk")
        let second = CatalogImportRow(
            line: 3, sourceID: "test", itemID: "2", name: " milk ", notes: "",
            categoryName: nil, storeNames: []
        )
        let preview = try service.previewCatalogImport(
            rows: [first, second], householdID: selection.householdID, listID: selection.listID
        )

        guard case .nameConflict = preview.entries[0].disposition,
              case .nameConflict = preview.entries[1].disposition else {
            return XCTFail("Both incoming duplicates must be reconciled in preview")
        }
        XCTAssertEqual(
            try service.applyCatalogImport(preview, actions: [first.id: .create, second.id: .create]),
            CatalogImportResult(created: 2, updated: 0, skipped: 0, changed: 0)
        )
        XCTAssertEqual(try itemCount(in: persistence), 2)

        let repeatPreview = try service.previewCatalogImport(
            rows: [first, second], householdID: selection.householdID, listID: selection.listID
        )
        XCTAssertEqual(
            try service.applyCatalogImport(repeatPreview, actions: [first.id: .update, second.id: .update]),
            CatalogImportResult(created: 0, updated: 2, skipped: 0, changed: 0)
        )
    }

    func testApplySkipsMappingsChangedAfterPreview() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let categoryID = try service.createCategory(name: "Dairy", householdID: selection.householdID)
        let storeID = try service.createStore(name: "Publix", householdID: selection.householdID)
        _ = try service.createStore(name: "Costco", householdID: selection.householdID)
        let imported = row(name: "Milk", category: "Dairy")
        let storeMapped = CatalogImportRow(
            line: 3, sourceID: "test", itemID: "2", name: "Bread", notes: "",
            categoryName: nil, storeNames: ["Publix", "Costco"]
        )
        let preview = try service.previewCatalogImport(
            rows: [imported, storeMapped], householdID: selection.householdID, listID: selection.listID
        )
        try service.renameCategory(name: "Refrigerated", categoryID: categoryID, householdID: selection.householdID)
        try service.setStoreArchived(true, storeID: storeID, householdID: selection.householdID)

        XCTAssertEqual(
            try service.applyCatalogImport(
                preview, actions: [imported.id: .create, storeMapped.id: .create]
            ),
            CatalogImportResult(created: 0, updated: 0, skipped: 0, changed: 2)
        )
        XCTAssertEqual(try itemCount(in: persistence), 0)
    }

    func testStableImportIdentityIsIndependentPerHousehold() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let firstHousehold = try service.createHousehold()
        let secondHousehold = try service.createHousehold()
        let imported = row(name: "Coffee")
        let firstPreview = try service.previewCatalogImport(
            rows: [imported], householdID: firstHousehold.householdID, listID: firstHousehold.listID
        )
        let secondPreview = try service.previewCatalogImport(
            rows: [imported], householdID: secondHousehold.householdID, listID: secondHousehold.listID
        )
        XCTAssertNotEqual(firstPreview.entries[0].catalogItemID, secondPreview.entries[0].catalogItemID)

        _ = try service.applyCatalogImport(firstPreview, actions: [imported.id: .create])
        _ = try service.applyCatalogImport(secondPreview, actions: [imported.id: .create])
        XCTAssertEqual(try itemCount(in: persistence), 2)
    }

    func testUpdateRejectsChangedLinkedPeerFromSameImport() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let first = row(name: "Milk")
        let second = CatalogImportRow(
            line: 3, sourceID: "test", itemID: "2", name: "Milk", notes: "",
            categoryName: nil, storeNames: []
        )
        let createPreview = try service.previewCatalogImport(
            rows: [first, second], householdID: selection.householdID, listID: selection.listID
        )
        _ = try service.applyCatalogImport(
            createPreview, actions: [first.id: .create, second.id: .create]
        )
        let updatePreview = try service.previewCatalogImport(
            rows: [first, second], householdID: selection.householdID, listID: selection.listID
        )
        let firstID = createPreview.entries[0].catalogItemID
        try service.saveCatalogItem(
            itemID: firstID,
            householdID: selection.householdID,
            values: CatalogItemValues(name: "Milk", notes: "Manual", categoryID: nil, anyStore: true, storeIDs: []),
            allowingNameCollision: true
        )

        XCTAssertEqual(
            try service.applyCatalogImport(updatePreview, actions: [first.id: .skip, second.id: .update]),
            CatalogImportResult(created: 0, updated: 0, skipped: 1, changed: 1)
        )
    }

    func testReviewedIntraBatchRenamesDoNotLookLikeExternalChanges() throws {
        let persistence = try PersistenceController(storeURL: temporaryStoreURL())
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let first = row(name: "Milk")
        let second = CatalogImportRow(
            line: 3, sourceID: "test", itemID: "2", name: "Milk", notes: "",
            categoryName: nil, storeNames: []
        )
        let createPreview = try service.previewCatalogImport(
            rows: [first, second], householdID: selection.householdID, listID: selection.listID
        )
        _ = try service.applyCatalogImport(
            createPreview, actions: [first.id: .create, second.id: .create]
        )

        let renamedFirst = row(name: "Oat Milk")
        let renameOutPreview = try service.previewCatalogImport(
            rows: [renamedFirst, second], householdID: selection.householdID, listID: selection.listID
        )
        XCTAssertEqual(
            try service.applyCatalogImport(
                renameOutPreview, actions: [renamedFirst.id: .update, second.id: .update]
            ),
            CatalogImportResult(created: 0, updated: 2, skipped: 0, changed: 0)
        )

        let renameInPreview = try service.previewCatalogImport(
            rows: [first, second], householdID: selection.householdID, listID: selection.listID
        )
        XCTAssertFalse(renameInPreview.entries[0].reviewedIncomingCollisionIDs.isEmpty)
        XCTAssertFalse(renameInPreview.entries[1].reviewedIncomingCollisionIDs.isEmpty)
        XCTAssertEqual(
            try service.applyCatalogImport(
                renameInPreview, actions: [first.id: .update, second.id: .update]
            ),
            CatalogImportResult(created: 0, updated: 2, skipped: 0, changed: 0)
        )
    }

    private func row(
        name: String,
        notes: String = "",
        category: String? = nil,
        stores: [String] = []
    ) -> CatalogImportRow {
        CatalogImportRow(
            line: 2, sourceID: "test", itemID: "1", name: name, notes: notes,
            categoryName: category, storeNames: stores
        )
    }

    private func itemCount(in persistence: PersistenceController) throws -> Int {
        let context = persistence.simulationContext()
        return try context.performAndWait { try context.count(for: Item.fetchRequest()) }
    }

    private func itemState(
        _ id: UUID,
        in persistence: PersistenceController
    ) throws -> (notes: String, categoryID: UUID?, storeIDs: Set<UUID>) {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let item = try XCTUnwrap(context.fetch(request).first)
            return (item.notes, item.category?.id, Set(item.stores?.map(\.id) ?? []))
        }
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingCatalogImportTests-\(UUID().uuidString).sqlite")
    }
}
