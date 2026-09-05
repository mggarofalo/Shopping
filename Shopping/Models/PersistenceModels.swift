import CoreData

@objc(Household)
final class Household: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var groceryList: GroceryList?
    @NSManaged var stores: Set<Store>?
    @NSManaged var items: Set<Item>?
    @NSManaged var categories: Set<Category>?
    @NSManaged var clearOperations: Set<ClearOperation>?
}

@objc(Store)
final class Store: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var displayOrder: Int64
    @NSManaged var isArchived: Bool
    @NSManaged var household: Household?
    @NSManaged var items: Set<Item>?
}

@objc(Item)
final class Item: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var notes: String
    @NSManaged var anyStore: Bool
    @NSManaged var isArchived: Bool
    @NSManaged var household: Household?
    @NSManaged var category: Category?
    @NSManaged var stores: Set<Store>?
    @NSManaged var needs: Set<Need>?
}

@objc(Category)
final class Category: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var displayOrder: Int64
    @NSManaged var household: Household?
    @NSManaged var items: Set<Item>?
}

@objc(GroceryList)
final class GroceryList: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var household: Household?
    @NSManaged var needs: Set<Need>?
    @NSManaged var clearOperations: Set<ClearOperation>?
}

@objc(Need)
final class Need: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var quantity: Int64
    @NSManaged var carted: Bool
    @NSManaged var urgency: String
    @NSManaged var revision: Int64
    @NSManaged var archived: Bool
    @NSManaged var clearOperationID: UUID?
    @NSManaged var list: GroceryList?
    @NSManaged var item: Item?
}

@objc(ClearOperation)
final class ClearOperation: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var createdAt: Date
    @NSManaged var snapshot: Data
    @NSManaged var household: Household?
    @NSManaged var list: GroceryList?
}

extension Household {
    @nonobjc class func fetchRequest() -> NSFetchRequest<Household> {
        NSFetchRequest(entityName: "Household")
    }
}

extension Store {
    @nonobjc class func fetchRequest() -> NSFetchRequest<Store> {
        NSFetchRequest(entityName: "Store")
    }
}

extension Item {
    @nonobjc class func fetchRequest() -> NSFetchRequest<Item> {
        NSFetchRequest(entityName: "Item")
    }
}

extension Category {
    @nonobjc class func fetchRequest() -> NSFetchRequest<Category> {
        NSFetchRequest(entityName: "Category")
    }
}

extension GroceryList {
    @nonobjc class func fetchRequest() -> NSFetchRequest<GroceryList> {
        NSFetchRequest(entityName: "GroceryList")
    }
}

extension Need {
    @nonobjc class func fetchRequest() -> NSFetchRequest<Need> {
        NSFetchRequest(entityName: "Need")
    }
}

extension ClearOperation {
    @nonobjc class func fetchRequest() -> NSFetchRequest<ClearOperation> {
        NSFetchRequest(entityName: "ClearOperation")
    }
}
