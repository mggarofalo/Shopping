import CoreData
import XCTest

@testable import Shopping

final class LocalDataRegressionTests: XCTestCase {
    func testRemovingCategoryWithExhaustedImportedRevisionRollsBackAllRelationships() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = NeedService(persistence: persistence)
        let ids = try service.createHousehold()
        let categoryID = try service.createCategory(name: "Frozen", householdID: ids.householdID)
        let itemID = try service.createItem(name: "Peas", categoryID: categoryID, householdID: ids.householdID)
        let needID = try service.addOneTimeNeed(title: "Ice", categoryID: categoryID, listID: ids.listID)
        let context = persistence.simulationContext()
        try context.performAndWait {
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", needID as CVarArg)
            let need = try XCTUnwrap(context.fetch(request).first)
            need.revision = .max
            try context.save()
        }
        XCTAssertThrowsError(try service.removeCategory(
            categoryID: categoryID, householdID: ids.householdID, listID: ids.listID
        )) { XCTAssertEqual($0 as? NeedServiceError, .scopeChanged) }
        try context.performAndWait {
            context.reset()
            let need = try XCTUnwrap(context.fetch(Need.fetchRequest()).first { $0.id == needID })
            let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first { $0.id == itemID })
            XCTAssertEqual(need.revision, .max)
            XCTAssertEqual(need.oneTimeCategory?.id, categoryID)
            XCTAssertEqual(item.category?.id, categoryID)
            XCTAssertEqual(try context.count(for: Category.fetchRequest()), 1)
        }
    }

    func testCompetingQuantityEditsUseLastLocalSaveInBothOrders() throws {
        for order in [LocalTwoContextHarness.SaveOrder.firstThenSecond, .secondThenFirst] {
            let harness = try LocalTwoContextHarness(storeURL: url())
            let service = NeedService(persistence: harness.persistence)
            let selection = try service.createHousehold()
            let needID = try service.addOneTimeNeed(
                title: "Milk", householdID: selection.householdID, listID: selection.listID)
            try stageNeed(harness, .first, needID) { $0.quantity = 2 }
            try stageNeed(harness, .second, needID) { $0.quantity = 7 }
            try harness.save(in: order)
            harness.reset(.first)
            harness.reset(.second)
            let expected: Int64 = order == .firstThenSecond ? 7 : 2
            XCTAssertEqual(try quantity(harness.first, needID), expected)
            XCTAssertEqual(try quantity(harness.second, needID), expected)
        }
    }

    func testIndependentTagAddsMergeAsUnionInBothOrders() throws {
        for order in [LocalTwoContextHarness.SaveOrder.firstThenSecond, .secondThenFirst] {
            let harness = try LocalTwoContextHarness(storeURL: url())
            let service = NeedService(persistence: harness.persistence)
            let selection = try service.createHousehold()
            let original = try service.createStore(name: "Original", householdID: selection.householdID)
            let first = try service.createStore(name: "First", householdID: selection.householdID)
            let second = try service.createStore(name: "Second", householdID: selection.householdID)
            let itemID = try service.createItem(
                name: "Rice", storeIDs: [original], householdID: selection.householdID, anyStore: false)
            try stageItem(harness, .first, itemID) { item, context in
                item.stores?.insert(try self.store(context, first))
            }
            try stageItem(harness, .second, itemID) { item, context in
                item.stores?.insert(try self.store(context, second))
            }
            try harness.save(in: order)
            harness.reset(.first)
            harness.reset(.second)
            XCTAssertEqual(try storeIDs(harness.first, itemID), Set([original, first, second]))
            XCTAssertEqual(try storeIDs(harness.second, itemID), Set([original, first, second]))
        }
    }

    func testDuplicateRememberedOccurrencesRequireExplicitRemovalAndDoNotUndoIntoConflict() throws {
        for order in [LocalTwoContextHarness.SaveOrder.firstThenSecond, .secondThenFirst] {
            let harness = try LocalTwoContextHarness(storeURL: url())
            let service = NeedService(persistence: harness.persistence)
            let selection = try service.createHousehold()
            let store = try service.createStore(name: "Costco", householdID: selection.householdID)
            let item = try service.createItem(
                name: "Tea", storeIDs: [store], householdID: selection.householdID, anyStore: false)
            let first = UUID()
            let second = UUID()
            try stageRemembered(harness, .first, first, item, selection.listID, 2, "first", .urgent, false)
            try stageRemembered(harness, .second, second, item, selection.listID, 9, "second", .normal, true)
            try harness.save(in: order)
            harness.reset(.first)
            let before = try occurrenceSnapshot(harness.first, first, second, item)
            XCTAssertEqual(before.first.quantity, 2)
            XCTAssertEqual(before.first.notes, "first")
            XCTAssertEqual(before.first.urgency, .urgent)
            XCTAssertFalse(before.first.carted)
            XCTAssertEqual(before.second.quantity, 9)
            XCTAssertEqual(before.second.notes, "second")
            XCTAssertEqual(before.second.urgency, .normal)
            XCTAssertTrue(before.second.carted)
            XCTAssertEqual(before.tags, [store])
            let group = try XCTUnwrap(
                try service.rememberedDuplicateGroups(
                    householdID: selection.householdID, listID: selection.listID
                ).first)
            let revision = try XCTUnwrap(group.candidates.first { $0.needID == second }).revision
            XCTAssertThrowsError(
                try service.removeNeed(
                    needID: second, householdID: selection.householdID, listID: selection.listID,
                    expectedRevision: revision + 1))
            harness.reset(.first)
            XCTAssertEqual(try occurrenceSnapshot(harness.first, first, second, item), before)
            let operation = try service.removeNeed(
                needID: second, householdID: selection.householdID, listID: selection.listID,
                expectedRevision: revision)
            harness.reset(.first)
            let after = try occurrenceSnapshot(harness.first, first, second, item)
            XCTAssertEqual(after.first, before.first)
            XCTAssertEqual(after.first.quantity, 2)
            XCTAssertEqual(after.first.notes, "first")
            XCTAssertEqual(after.first.urgency, .urgent)
            XCTAssertFalse(after.first.carted)
            XCTAssertTrue(after.second.archived)
            XCTAssertEqual(after.second.quantity, 9)
            XCTAssertEqual(after.second.notes, "second")
            XCTAssertEqual(after.second.urgency, .normal)
            XCTAssertTrue(after.second.carted)
            XCTAssertEqual(after.second.revision, before.second.revision + 1)
            XCTAssertEqual(after.second.clearOperationID, operation)
            XCTAssertEqual(after.tags, [store])
            XCTAssertEqual(
                try service.undoClear(
                    operationID: operation, expectedHouseholdID: selection.householdID,
                    expectedListID: selection.listID), 0)
            harness.reset(.first)
            XCTAssertEqual(try occurrenceSnapshot(harness.first, first, second, item), after)
        }
    }

    private func stageRemembered(
        _ h: LocalTwoContextHarness, _ r: LocalTwoContextHarness.Replica, _ id: UUID, _ itemID: UUID,
        _ listID: UUID, _ quantity: Int64, _ notes: String, _ urgency: NeedUrgency, _ carted: Bool
    ) throws {
        try h.stage(r) { c in
            let ir = Item.fetchRequest()
            ir.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            let lr = GroceryList.fetchRequest()
            lr.predicate = NSPredicate(format: "id == %@", listID as CVarArg)
            let need = NSEntityDescription.insertNewObject(forEntityName: "Need", into: c) as! Need
            need.id = id
            need.kind = NeedKind.remembered.rawValue
            need.title = "Tea"
            need.quantity = quantity
            need.notes = notes
            need.urgency = urgency.rawValue
            need.carted = carted
            need.archived = false
            need.revision = 0
            need.item = try XCTUnwrap(try c.fetch(ir).first)
            need.list = try XCTUnwrap(try c.fetch(lr).first)
        }
    }
    private struct Occurrence: Equatable {
        let quantity: Int64?
        let notes: String
        let urgency: NeedUrgency
        let carted: Bool
        let archived: Bool
        let revision: Int64
        let clearOperationID: UUID?

        init(_ need: Need) {
            quantity = need.quantity
            notes = need.notes
            urgency = NeedUrgency(rawValue: need.urgency)!
            carted = need.carted
            archived = need.archived
            revision = need.revision
            clearOperationID = need.clearOperationID
        }
    }

    private struct Snapshot: Equatable {
        let first: Occurrence
        let second: Occurrence
        let tags: Set<UUID>
    }

    private func occurrenceSnapshot(_ c: NSManagedObjectContext, _ first: UUID, _ second: UUID, _ item: UUID)
        throws -> Snapshot
    {
        try c.performAndWait {
            let r = Need.fetchRequest()
            let values = try c.fetch(r)
            let a = try XCTUnwrap(values.first { $0.id == first })
            let b = try XCTUnwrap(values.first { $0.id == second })
            let ir = Item.fetchRequest()
            ir.predicate = NSPredicate(format: "id == %@", item as CVarArg)
            let i = try XCTUnwrap(try c.fetch(ir).first)
            return Snapshot(
                first: Occurrence(a), second: Occurrence(b), tags: Set(i.stores?.map(\.id) ?? [])
            )
        }
    }

    private func stageNeed(
        _ h: LocalTwoContextHarness, _ r: LocalTwoContextHarness.Replica, _ id: UUID,
        change: @escaping (Need) -> Void
    ) throws {
        try h.stage(r) { c in
            let q = Need.fetchRequest()
            q.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            change(try XCTUnwrap(try c.fetch(q).first))
        }
    }
    private func stageItem(
        _ h: LocalTwoContextHarness, _ r: LocalTwoContextHarness.Replica, _ id: UUID,
        change: @escaping (Item, NSManagedObjectContext) throws -> Void
    ) throws {
        try h.stage(r) { c in
            let q = Item.fetchRequest()
            q.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            try change(try XCTUnwrap(try c.fetch(q).first), c)
        }
    }
    private func store(_ c: NSManagedObjectContext, _ id: UUID) throws -> Store {
        let q = Store.fetchRequest()
        q.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(try c.fetch(q).first)
    }
    private func quantity(_ c: NSManagedObjectContext, _ id: UUID) throws -> Int64 {
        try c.performAndWait {
            let q = Need.fetchRequest()
            q.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return try XCTUnwrap(try XCTUnwrap(try c.fetch(q).first).quantity)
        }
    }
    private func storeIDs(_ c: NSManagedObjectContext, _ id: UUID) throws -> Set<UUID> {
        try c.performAndWait {
            let q = Item.fetchRequest()
            q.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return Set(try XCTUnwrap(try c.fetch(q).first).stores?.map(\.id) ?? [])
        }
    }
    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "Shopping29-\(UUID().uuidString).sqlite")
    }
}
