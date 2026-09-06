import CoreData
import XCTest

@testable import Shopping

final class OptionalQuantityTests: XCTestCase {
    func testNewNeedsStartUnsetAndCommandsCanSetAndClearQuantity() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let needID = try service.addOneTimeNeed(
            title: "Loose apples",
            householdID: selection.householdID,
            listID: selection.listID
        )

        XCTAssertNil(try quantity(needID, in: persistence))
        XCTAssertNil(try primitiveQuantity(needID, in: persistence))
        try service.setNeedQuantity(
            needID: needID,
            householdID: selection.householdID,
            listID: selection.listID,
            quantity: 6
        )
        XCTAssertEqual(try quantity(needID, in: persistence), 6)
        XCTAssertEqual(try primitiveQuantity(needID, in: persistence)?.int64Value, 6)
        try service.setNeedQuantity(
            needID: needID,
            householdID: selection.householdID,
            listID: selection.listID,
            quantity: nil
        )
        XCTAssertNil(try quantity(needID, in: persistence))
        XCTAssertThrowsError(try service.setQuantity(100, needID: needID)) {
            XCTAssertEqual($0 as? NeedServiceError, .invalidQuantity)
        }
    }

    func testClearUndoPromotionAndReaddPreserveUnsetAndNumericQuantities() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let itemID = try service.createItem(name: "Coffee", householdID: selection.householdID)
        let rememberedID = try service.addRememberedNeed(
            itemID: itemID,
            listID: selection.listID,
            householdID: selection.householdID,
            quantity: 4
        )
        let oneTimeID = try service.addOneTimeNeed(
            title: "Tea",
            householdID: selection.householdID,
            listID: selection.listID
        )
        try service.setNeedCarted(
            needID: rememberedID,
            householdID: selection.householdID,
            listID: selection.listID,
            carted: true
        )
        try service.setNeedCarted(
            needID: oneTimeID,
            householdID: selection.householdID,
            listID: selection.listID,
            carted: true
        )
        let preview = try service.prepareClearCarted(
            householdID: selection.householdID,
            listID: selection.listID,
            filter: GroceryNeedFilter()
        )
        XCTAssertEqual(preview.rows.first(where: { $0.needID == rememberedID })?.quantity, 4)
        XCTAssertNil(preview.rows.first(where: { $0.needID == oneTimeID })?.quantity)
        XCTAssertEqual(try service.clearCarted(using: preview.token), 2)
        XCTAssertEqual(try service.undoClear(operationID: preview.token.id), 2)
        XCTAssertEqual(try quantity(rememberedID, in: persistence), 4)
        XCTAssertNil(try quantity(oneTimeID, in: persistence))

        _ = try service.rememberOneTimeGrocery(
            needID: oneTimeID,
            householdID: selection.householdID,
            listID: selection.listID,
            existingItemID: try service.createItem(name: "Tea", householdID: selection.householdID),
            need: RememberedNeedValues(quantity: nil, purchaseNotes: "", urgency: .normal)
        )
        XCTAssertNil(try quantity(oneTimeID, in: persistence))
        XCTAssertEqual(
            try service.addRememberedNeed(itemID: itemID, listID: selection.listID),
            rememberedID
        )
        XCTAssertEqual(try quantity(rememberedID, in: persistence), 4)
    }

    func testSimulatedReplicasPreserveNilAndNumericQuantitySeparately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OptionalQuantity-\(UUID().uuidString)")
        let storeURL = directory.appendingPathComponent("Store.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let harness = try LocalTwoContextHarness(storeURL: storeURL)
        let service = NeedService(persistence: harness.persistence)
        let selection = try service.createHousehold()
        let numericID = try service.addOneTimeNeed(title: "Bags", quantity: 2, listID: selection.listID)
        let unsetID = try service.addOneTimeNeed(title: "Loose fruit", listID: selection.listID)

        try harness.stage(.first) { context in
            try self.setQuantity(7, for: numericID, in: context)
        }
        try harness.stage(.second) { context in
            try self.setQuantity(nil, for: unsetID, in: context)
        }
        try harness.save(in: .firstThenSecond)
        harness.reset(.first)
        harness.reset(.second)

        XCTAssertEqual(try quantity(numericID, in: harness.persistence), 7)
        XCTAssertNil(try quantity(unsetID, in: harness.persistence))
    }

    private func setQuantity(_ value: Int64?, for needID: UUID, in context: NSManagedObjectContext) throws {
        let request = Need.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
        try XCTUnwrap(context.fetch(request).first).quantity = value
    }

    private func primitiveQuantity(_ needID: UUID, in persistence: PersistenceController) throws -> NSNumber?
    {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            return try XCTUnwrap(context.fetch(request).first).primitiveValue(forKey: "quantity") as? NSNumber
        }
    }

    private func quantity(_ needID: UUID, in persistence: PersistenceController) throws -> Int64? {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            return try XCTUnwrap(context.fetch(request).first).quantity
        }
    }
}
