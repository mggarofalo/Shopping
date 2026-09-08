import CoreData
import Testing

@testable import Shopping

@Suite("Optional quantity persistence", .tags(.integration, .persistence, .critical))
struct OptionalQuantityTests {
    @Test("New needs start unset and commands set or clear quantity")
    func newNeedsStartUnsetAndCommandsCanSetAndClearQuantity() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold()
        let needID = try service.addOneTimeNeed(
            title: "Loose apples",
            householdID: selection.householdID,
            listID: selection.listID
        )

        #expect(try quantity(needID, in: persistence) == nil)
        #expect(try primitiveQuantity(needID, in: persistence) == nil)
        try service.setNeedQuantity(
            needID: needID,
            householdID: selection.householdID,
            listID: selection.listID,
            quantity: 6
        )
        #expect(try quantity(needID, in: persistence) == 6)
        #expect(try primitiveQuantity(needID, in: persistence)?.int64Value == 6)
        try service.setNeedQuantity(
            needID: needID,
            householdID: selection.householdID,
            listID: selection.listID,
            quantity: nil
        )
        #expect(try quantity(needID, in: persistence) == nil)
        do {
            try service.setQuantity(100, needID: needID)
            Issue.record("Expected an invalid quantity error")
        } catch {
            #expect(error as? NeedServiceError == .invalidQuantity)
        }
    }

    @Test("Clear, undo, promotion, and re-add preserve optional quantity")
    func clearUndoPromotionAndReaddPreserveUnsetAndNumericQuantities() throws {
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
        #expect(preview.rows.first(where: { $0.needID == rememberedID })?.quantity == 4)
        #expect(preview.rows.first(where: { $0.needID == oneTimeID })?.quantity == nil)
        #expect(try service.clearCarted(using: preview.token) == 2)
        #expect(try service.undoClear(operationID: preview.token.id) == 2)
        #expect(try quantity(rememberedID, in: persistence) == 4)
        #expect(try quantity(oneTimeID, in: persistence) == nil)

        _ = try service.rememberOneTimeGrocery(
            needID: oneTimeID,
            householdID: selection.householdID,
            listID: selection.listID,
            existingItemID: try service.createItem(name: "Tea", householdID: selection.householdID),
            need: RememberedNeedValues(quantity: nil, purchaseNotes: "", urgency: .normal)
        )
        #expect(try quantity(oneTimeID, in: persistence) == nil)
        #expect(try service.addRememberedNeed(itemID: itemID, listID: selection.listID) == rememberedID)
        #expect(try quantity(rememberedID, in: persistence) == 4)
    }

    @Test("Simulated replicas preserve nil and numeric quantity independently")
    func simulatedReplicasPreserveNilAndNumericQuantitySeparately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OptionalQuantity-\(UUID().uuidString)")
        let storeURL = directory.appendingPathComponent("Store.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let harness = try LocalTwoContextHarness(storeURL: storeURL)
        let coordinator = harness.persistence.container.persistentStoreCoordinator
        defer {
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }
        let service = NeedService(persistence: harness.persistence)
        let selection = try service.createHousehold()
        let numericID = try service.addOneTimeNeed(
            title: "Bags", quantity: 2, listID: selection.listID)
        let unsetID = try service.addOneTimeNeed(
            title: "Loose fruit", listID: selection.listID)

        try harness.stage(.first) { context in
            try self.setQuantity(7, for: numericID, in: context)
        }
        try harness.stage(.second) { context in
            try self.setQuantity(nil, for: unsetID, in: context)
        }
        try harness.save(in: .firstThenSecond)
        harness.reset(.first)
        harness.reset(.second)

        #expect(try quantity(numericID, in: harness.persistence) == 7)
        #expect(try quantity(unsetID, in: harness.persistence) == nil)
    }

    private func setQuantity(_ value: Int64?, for needID: UUID, in context: NSManagedObjectContext) throws {
        let request = Need.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
        let need = try #require(context.fetch(request).first)
        need.quantity = value
    }

    private func primitiveQuantity(_ needID: UUID, in persistence: PersistenceController) throws -> NSNumber?
    {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let need = try #require(context.fetch(request).first)
            return need.primitiveValue(forKey: "quantity") as? NSNumber
        }
    }

    private func quantity(_ needID: UUID, in persistence: PersistenceController) throws -> Int64? {
        let context = persistence.simulationContext()
        return try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            return try #require(context.fetch(request).first).quantity
        }
    }
}
