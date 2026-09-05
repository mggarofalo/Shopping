import CoreData
import Foundation

enum FixtureGenerationError: Error {
    case usage
    case modelUnreadable
}

struct FixtureClearCartedToken: Codable {
    let id: UUID
    let householdID: UUID
    let listID: UUID
    let revisionsByNeedID: [UUID: Int64]
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { throw FixtureGenerationError.usage }
guard let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    throw FixtureGenerationError.modelUnreadable
}

let storeURL = URL(fileURLWithPath: arguments[2])
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
let store = try coordinator.addPersistentStore(
    ofType: NSSQLiteStoreType,
    configurationName: nil,
    at: storeURL,
    options: nil
)
let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator

func insert(_ entityName: String) -> NSManagedObject {
    NSManagedObject(entity: model.entitiesByName[entityName]!, insertInto: context)
}

let household = insert("Household")
household.setValue(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!, forKey: "id")
household.setValue("Fixture household", forKey: "name")

let list = insert("GroceryList")
list.setValue(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!, forKey: "id")
list.setValue(household, forKey: "household")

let storeObject = insert("Store")
storeObject.setValue(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!, forKey: "id")
storeObject.setValue("Costco", forKey: "name")
storeObject.setValue(household, forKey: "household")

let category = insert("Category")
category.setValue(UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!, forKey: "id")
category.setValue("Frozen", forKey: "name")
category.setValue(household, forKey: "household")

let operation = insert("ClearOperation")
operation.setValue(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, forKey: "id")
operation.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "createdAt")
operation.setValue(
    try JSONEncoder().encode(
        FixtureClearCartedToken(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            householdID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            listID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            revisionsByNeedID: [UUID(uuidString: "11111111-1111-1111-1111-111111111111")!: 8]
        )
    ),
    forKey: "snapshot"
)
operation.setValue(household, forKey: "household")
operation.setValue(list, forKey: "list")

let need = insert("Need")
need.setValue(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, forKey: "id")
need.setValue("oneTime", forKey: "kind")
need.setValue("Party ice", forKey: "title")
need.setValue("Keep cold", forKey: "notes")
need.setValue(Int64(4), forKey: "quantity")
need.setValue(true, forKey: "carted")
need.setValue("urgent", forKey: "urgency")
need.setValue(Int64(9), forKey: "revision")
need.setValue(true, forKey: "archived")
need.setValue(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, forKey: "clearOperationID")
need.setValue(false, forKey: "oneTimeAnyStore")
need.setValue(list, forKey: "list")
need.setValue(category, forKey: "oneTimeCategory")
need.mutableSetValue(forKey: "oneTimeStores").add(storeObject)

try context.save()
try coordinator.remove(store)
