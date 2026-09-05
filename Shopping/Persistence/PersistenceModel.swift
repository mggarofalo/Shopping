import CoreData

enum PersistenceModel {
    // Experimental local schema; SHOPPING-20 will freeze the versioned production model and fixtures.
    static let name = "Shopping"
    private static let unsetID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let household = entity("Household", Household.self, [
            attribute("id", .UUIDAttributeType, unsetID),
            attribute("name", .stringAttributeType, "Household")
        ])
        let store = entity("Store", Store.self, [
            attribute("id", .UUIDAttributeType, unsetID),
            attribute("name", .stringAttributeType, ""),
            attribute("displayOrder", .integer64AttributeType, 0),
            attribute("isArchived", .booleanAttributeType, false)
        ])
        let category = entity("Category", Category.self, [
            attribute("id", .UUIDAttributeType, unsetID),
            attribute("name", .stringAttributeType, ""),
            attribute("displayOrder", .integer64AttributeType, 0)
        ])
        let item = entity("Item", Item.self, [
            attribute("id", .UUIDAttributeType, unsetID),
            attribute("name", .stringAttributeType, ""),
            attribute("notes", .stringAttributeType, ""),
            attribute("anyStore", .booleanAttributeType, true),
            attribute("isArchived", .booleanAttributeType, false)
        ])
        let list = entity("GroceryList", GroceryList.self, [
            attribute("id", .UUIDAttributeType, unsetID)
        ])
        let need = entity("Need", Need.self, [
            attribute("id", .UUIDAttributeType, unsetID),
            attribute("title", .stringAttributeType, ""),
            attribute("quantity", .integer64AttributeType, 1),
            attribute("carted", .booleanAttributeType, false),
            attribute("urgency", .stringAttributeType, "normal"),
            attribute("revision", .integer64AttributeType, 0),
            attribute("archived", .booleanAttributeType, false),
            attribute("clearOperationID", .UUIDAttributeType, nil, optional: true)
        ])
        let clearOperation = entity("ClearOperation", ClearOperation.self, [
            attribute("id", .UUIDAttributeType, unsetID),
            attribute("createdAt", .dateAttributeType, Date(timeIntervalSince1970: 0)),
            attribute("snapshot", .binaryDataAttributeType, Data())
        ])

        relate(household, "groceryList", list, "household", toManyDestination: false, toManySource: false)
        relate(household, "stores", store, "household", toManyDestination: true, toManySource: false)
        relate(household, "categories", category, "household", toManyDestination: true, toManySource: false)
        relate(household, "items", item, "household", toManyDestination: true, toManySource: false)
        relate(category, "items", item, "category", toManyDestination: true, toManySource: false)
        relate(item, "stores", store, "items", toManyDestination: true, toManySource: true)
        relate(list, "needs", need, "list", toManyDestination: true, toManySource: false)
        relate(item, "needs", need, "item", toManyDestination: true, toManySource: false)
        relate(household, "clearOperations", clearOperation, "household", toManyDestination: true, toManySource: false)
        relate(list, "clearOperations", clearOperation, "list", toManyDestination: true, toManySource: false)

        model.entities = [household, store, category, item, list, need, clearOperation]
        return model
    }

    private static func entity(
        _ name: String,
        _ type: NSManagedObject.Type,
        _ properties: [NSPropertyDescription]
    ) -> NSEntityDescription {
        let result = NSEntityDescription()
        result.name = name
        result.managedObjectClassName = NSStringFromClass(type)
        result.properties = properties
        return result
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        _ defaultValue: Any?,
        optional: Bool = false
    ) -> NSAttributeDescription {
        let result = NSAttributeDescription()
        result.name = name
        result.attributeType = type
        result.isOptional = optional
        result.defaultValue = defaultValue
        return result
    }

    private static func relate(
        _ source: NSEntityDescription,
        _ sourceName: String,
        _ destination: NSEntityDescription,
        _ destinationName: String,
        toManyDestination: Bool,
        toManySource: Bool
    ) {
        let forward = relationship(sourceName, destination, toMany: toManyDestination)
        let inverse = relationship(destinationName, source, toMany: toManySource)
        forward.inverseRelationship = inverse
        inverse.inverseRelationship = forward
        source.properties.append(forward)
        destination.properties.append(inverse)
    }

    private static func relationship(
        _ name: String,
        _ destination: NSEntityDescription,
        toMany: Bool
    ) -> NSRelationshipDescription {
        let result = NSRelationshipDescription()
        result.name = name
        result.destinationEntity = destination
        result.isOptional = true
        result.minCount = 0
        result.maxCount = toMany ? 0 : 1
        result.deleteRule = .nullifyDeleteRule
        result.isOrdered = false
        return result
    }
}
