import CoreData
import XCTest
@testable import Shopping

final class SchemaVersionTests: XCTestCase {
    func testBundledV2ModelPreservesProductionSchemaContract() throws {
        let model = try PersistenceModel.make()

        XCTAssertEqual(model.versionIdentifiers, [PersistenceModel.versionIdentifier])
        XCTAssertEqual(Set(model.entities.compactMap(\.name)), [
            "Household", "Store", "Category", "Item", "GroceryList", "Need", "ClearOperation"
        ])

        let need = try XCTUnwrap(model.entitiesByName["Need"])
        XCTAssertEqual(need.managedObjectClassName, NSStringFromClass(Need.self))
        XCTAssertEqual(try attribute("kind", in: need).defaultValue as? String, "")
        XCTAssertEqual(try attribute("title", in: need).defaultValue as? String, "")
        let quantity = try attribute("quantity", in: need)
        XCTAssertTrue(quantity.isOptional)
        XCTAssertNil(quantity.defaultValue)
        XCTAssertEqual(try attribute("notes", in: need).defaultValue as? String, "")
        XCTAssertEqual(try attribute("carted", in: need).defaultValue as? Bool, false)
        XCTAssertEqual(try attribute("urgency", in: need).defaultValue as? String, "normal")
        XCTAssertEqual(try attribute("revision", in: need).defaultValue as? Int64, 0)
        XCTAssertEqual(try attribute("archived", in: need).defaultValue as? Bool, false)
        XCTAssertEqual(try attribute("oneTimeAnyStore", in: need).defaultValue as? Bool, false)
        XCTAssertEqual(try attribute("clearOperationID", in: need).isOptional, true)
        assertMissingIDStorage(in: need)

        let household = try XCTUnwrap(model.entitiesByName["Household"])
        assertMissingIDStorage(in: household)
        XCTAssertEqual(try attribute("name", in: household).defaultValue as? String, "Household")
        let store = try XCTUnwrap(model.entitiesByName["Store"])
        assertMissingIDStorage(in: store)
        XCTAssertEqual(try attribute("name", in: store).defaultValue as? String, "")
        XCTAssertEqual(try attribute("displayOrder", in: store).defaultValue as? Int64, 0)
        XCTAssertEqual(try attribute("isArchived", in: store).defaultValue as? Bool, false)
        let category = try XCTUnwrap(model.entitiesByName["Category"])
        assertMissingIDStorage(in: category)
        XCTAssertEqual(try attribute("name", in: category).defaultValue as? String, "")
        XCTAssertEqual(try attribute("displayOrder", in: category).defaultValue as? Int64, 0)
        let item = try XCTUnwrap(model.entitiesByName["Item"])
        assertMissingIDStorage(in: item)
        XCTAssertEqual(try attribute("name", in: item).defaultValue as? String, "")
        XCTAssertEqual(try attribute("notes", in: item).defaultValue as? String, "")
        XCTAssertEqual(try attribute("anyStore", in: item).defaultValue as? Bool, true)
        XCTAssertEqual(try attribute("isArchived", in: item).defaultValue as? Bool, false)
        let groceryList = try XCTUnwrap(model.entitiesByName["GroceryList"])
        assertMissingIDStorage(in: groceryList)
        let operation = try XCTUnwrap(model.entitiesByName["ClearOperation"])
        XCTAssertEqual(try attribute("createdAt", in: operation).defaultValue as? Date, Date(timeIntervalSince1970: 0))
        assertMissingIDStorage(in: operation)
        XCTAssertTrue(try attribute("snapshot", in: operation).isOptional)

        for entity in model.entities {
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            for relationship in entity.relationshipsByName.values {
                XCTAssertTrue(relationship.isOptional, "\(entity.name ?? "unknown").\(relationship.name)")
                XCTAssertFalse(relationship.isOrdered, "\(entity.name ?? "unknown").\(relationship.name)")
                XCTAssertEqual(relationship.deleteRule, .nullifyDeleteRule)
                XCTAssertNotNil(relationship.inverseRelationship)
            }
        }

    }

    func testOptionalIDStorageUsesSentinelFallbackAndRejectsMissingOccurrenceIdentity() throws {
        let persistence = try PersistenceController(inMemory: true)
        let ids = try NeedService(persistence: persistence).createHousehold()
        let context = persistence.simulationContext()
        try context.performAndWait {
            let listRequest = GroceryList.fetchRequest()
            listRequest.predicate = NSPredicate(format: "id == %@", ids.listID as CVarArg)
            let list = try XCTUnwrap(context.fetch(listRequest).first)
            let need = NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as! Need
            need.kind = NeedKind.oneTime.rawValue
            need.title = "Incomplete import"
            need.carted = true
            need.list = list
            XCTAssertNil(need.primitiveValue(forKey: "id"))
            XCTAssertEqual(need.id, PersistenceModel.unsetID)
            try context.save()
        }
        XCTAssertThrowsError(try NeedService(persistence: persistence).captureCarted(
            householdID: ids.householdID,
            listID: ids.listID
        )) { error in
            XCTAssertEqual(error as? NeedServiceError, .invalidOccurrenceIdentity)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingIDAccessor-\(UUID().uuidString)")
        let storeURL = directory.appendingPathComponent("Store.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expectedID = UUID()
        do {
            let persistent = try PersistenceController(storeURL: storeURL)
            let savedContext = persistent.simulationContext()
            try savedContext.performAndWait {
                let household = NSEntityDescription.insertNewObject(forEntityName: "Household", into: savedContext) as! Household
                XCTAssertNil(household.primitiveValue(forKey: "id"))
                XCTAssertEqual(household.id, PersistenceModel.unsetID)
                household.id = expectedID
                household.name = "Saved ID"
                try savedContext.save()
            }
            try close(persistent, contexts: [savedContext])
        }
        do {
            let reopened = try PersistenceController(storeURL: storeURL)
            let reopenedContext = reopened.simulationContext()
            try reopenedContext.performAndWait {
                let household = try XCTUnwrap(reopenedContext.fetch(Household.fetchRequest()).first)
                XCTAssertEqual(household.id, expectedID)
                XCTAssertEqual(household.primitiveValue(forKey: "id") as? UUID, expectedID)
            }
            try close(reopened, contexts: [reopenedContext])
        }
        try FileManager.default.removeItem(at: directory)
    }

    func testSavedV1FixtureIsCompatibleAndPreservesRecoveryGraph() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "ShoppingV1Recovery", withExtension: "sqlite", subdirectory: "Fixtures")
        )
        let model = try PersistenceModel.make()
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: fixtureURL,
            options: nil
        )
        XCTAssertFalse(model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata))

        let migrationDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingV1Migration-\(UUID().uuidString)")
        let migratedStoreURL = migrationDirectoryURL.appendingPathComponent("ShoppingV1Recovery.sqlite")
        try FileManager.default.createDirectory(at: migrationDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL, to: migratedStoreURL)
        let migrated = try PersistenceController(storeURL: migratedStoreURL)
        let context = migrated.simulationContext()
        try context.performAndWait {
            let needRequest = Need.fetchRequest()
            needRequest.predicate = NSPredicate(format: "id == %@", UUID(uuidString: "11111111-1111-1111-1111-111111111111")! as CVarArg)
            let need = try XCTUnwrap(context.fetch(needRequest).first)
            XCTAssertEqual(need.kind, NeedKind.oneTime.rawValue)
            XCTAssertEqual(need.quantity, 4)
            XCTAssertEqual(need.notes, "Keep cold")
            XCTAssertTrue(need.carted)
            XCTAssertTrue(need.archived)
            XCTAssertEqual(need.clearOperationID, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
            XCTAssertEqual(need.oneTimeCategory?.name, "Frozen")
            XCTAssertEqual(need.oneTimeStores?.map(\.name), ["Costco"])
            XCTAssertEqual(need.list?.household?.name, "Fixture household")

            let operationRequest = ClearOperation.fetchRequest()
            operationRequest.predicate = NSPredicate(format: "id == %@", UUID(uuidString: "22222222-2222-2222-2222-222222222222")! as CVarArg)
            let operation = try XCTUnwrap(context.fetch(operationRequest).first)
            let token = try JSONDecoder().decode(ClearCartedToken.self, from: XCTUnwrap(operation.snapshot))
            XCTAssertEqual(token.id, operation.id)
            XCTAssertEqual(token.householdID, need.list?.household?.id)
            XCTAssertEqual(token.listID, need.list?.id)
            XCTAssertEqual(token.revisionsByNeedID, [need.id: 8])
            XCTAssertEqual(need.revision, 9)
            XCTAssertEqual(operation.list?.id, need.list?.id)
        }

        try close(migrated, contexts: [context])
        try FileManager.default.removeItem(at: migrationDirectoryURL)

        let recoveryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingV1Recovery-\(UUID().uuidString)")
        let recoveryStoreURL = recoveryDirectoryURL.appendingPathComponent("ShoppingV1Recovery.sqlite")
        try FileManager.default.createDirectory(at: recoveryDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL, to: recoveryStoreURL)
        do {
            let persistence = try PersistenceController(storeURL: recoveryStoreURL)
            let service = NeedService(persistence: persistence)
            XCTAssertEqual(try service.undoClear(operationID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!), 1)
            let recoveryContext = persistence.simulationContext()
            try recoveryContext.performAndWait {
                let request = Need.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", UUID(uuidString: "11111111-1111-1111-1111-111111111111")! as CVarArg)
                let recovered = try XCTUnwrap(recoveryContext.fetch(request).first)
                XCTAssertFalse(recovered.archived)
                XCTAssertTrue(recovered.carted)
                XCTAssertEqual(recovered.kind, NeedKind.oneTime.rawValue)
                XCTAssertEqual(recovered.notes, "Keep cold")
                XCTAssertEqual(recovered.oneTimeCategory?.name, "Frozen")
                XCTAssertEqual(recovered.oneTimeStores?.map(\.name), ["Costco"])
            }
            try close(persistence, contexts: [recoveryContext])
        }
        try FileManager.default.removeItem(at: recoveryDirectoryURL)
    }

    private func close(_ persistence: PersistenceController, contexts: [NSManagedObjectContext]) throws {
        for context in contexts + [persistence.writer, persistence.container.viewContext] {
            context.performAndWait { context.reset() }
        }
        let coordinator = persistence.container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try coordinator.remove(store) }
    }

    private func attribute(_ name: String, in entity: NSEntityDescription) throws -> NSAttributeDescription {
        try XCTUnwrap(entity.attributesByName[name])
    }

    private func assertMissingIDStorage(in entity: NSEntityDescription) {
        let id = entity.attributesByName["id"]
        XCTAssertTrue(id?.isOptional == true, "\(entity.name ?? "unknown").id")
        XCTAssertNil(id?.defaultValue, "\(entity.name ?? "unknown").id")
    }
}
