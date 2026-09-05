import CoreData

struct ClearCartedToken: Codable, Equatable {
    let id: UUID
    let householdID: UUID
    let listID: UUID
    let revisionsByNeedID: [UUID: Int64]
}

enum NeedServiceError: Error, Equatable {
    case householdNotFound
    case listNotFound
    case itemNotFound
    case needNotFound
    case storeNotFound
    case categoryNotFound
    case scopeChanged
    case invalidQuantity
    case invalidName
}

enum StoreEligibility: Equatable {
    case anyStore
    case activeStores([UUID])
    case needsStore
}

final class NeedService {
    private let persistence: PersistenceController
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    @discardableResult
    func createHousehold(name: String = "Household") throws -> (householdID: UUID, listID: UUID) {
        return try write { context in
            let household: Household = self.insert("Household", in: context)
            household.id = UUID()
            household.name = name
            let list: GroceryList = self.insert("GroceryList", in: context)
            list.id = UUID()
            self.route(list, with: household, in: context)
            list.household = household
            return (household.id, list.id)
        }
    }

    @discardableResult
    func createStore(name: String, householdID: UUID, displayOrder: Int64 = 0) throws -> UUID {
        let name = try validatedName(name)
        return try write { context in
            guard let household = try self.household(id: householdID, in: context) else {
                throw NeedServiceError.householdNotFound
            }
            let store: Store = self.insert("Store", in: context)
            store.id = UUID()
            store.name = name
            store.displayOrder = displayOrder
            store.isArchived = false
            self.route(store, with: household, in: context)
            store.household = household
            return store.id
        }
    }

    @discardableResult
    func createCategory(name: String, householdID: UUID, displayOrder: Int64 = 0) throws -> UUID {
        let name = try validatedName(name)
        return try write { context in
            guard let household = try self.household(id: householdID, in: context) else {
                throw NeedServiceError.householdNotFound
            }
            let category: Category = self.insert("Category", in: context)
            category.id = UUID()
            category.name = name
            category.displayOrder = displayOrder
            self.route(category, with: household, in: context)
            category.household = household
            return category.id
        }
    }

    func setStoreArchived(_ archived: Bool, storeID: UUID, householdID: UUID) throws {
        try write { context in
            guard let store = try self.store(id: storeID, in: context) else {
                throw NeedServiceError.storeNotFound
            }
            guard store.household?.id == householdID else {
                throw NeedServiceError.scopeChanged
            }
            store.isArchived = archived
        }
    }

    func setCategory(itemID: UUID, categoryID: UUID?) throws {
        try write { context in
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard let itemHousehold = item.household else {
                throw NeedServiceError.scopeChanged
            }
            guard let categoryID else {
                item.category = nil
                return
            }
            guard let category = try self.category(id: categoryID, in: context) else {
                throw NeedServiceError.categoryNotFound
            }
            guard category.household == itemHousehold,
                  category.objectID.persistentStore == item.objectID.persistentStore else {
                throw NeedServiceError.scopeChanged
            }
            item.category = category
        }
    }

    func removeCategory(categoryID: UUID, householdID: UUID) throws {
        try write { context in
            guard let category = try self.category(id: categoryID, in: context) else {
                throw NeedServiceError.categoryNotFound
            }
            guard category.household?.id == householdID else {
                throw NeedServiceError.scopeChanged
            }
            context.delete(category)
        }
    }

    @discardableResult
    func createItem(name: String, householdID: UUID, anyStore: Bool = true) throws -> UUID {
        try write { context in
            guard let household = try self.household(id: householdID, in: context) else {
                throw NeedServiceError.householdNotFound
            }
            let item: Item = self.insert("Item", in: context)
            item.id = UUID()
            item.name = name
            item.anyStore = anyStore
            self.route(item, with: household, in: context)
            item.household = household
            return item.id
        }
    }

    func setStoreTags(itemID: UUID, storeIDs: Set<UUID>) throws {
        try write { context in
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard let itemHousehold = item.household else {
                throw NeedServiceError.scopeChanged
            }
            let request = Store.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", Array(storeIDs))
            let stores = try context.fetch(request)
            guard stores.count == storeIDs.count,
                  stores.allSatisfy({
                      $0.household == itemHousehold &&
                      $0.objectID.persistentStore == item.objectID.persistentStore
                  }) else {
                throw NeedServiceError.scopeChanged
            }
            item.stores = Set(stores)
        }
    }

    func storeEligibility(itemID: UUID) throws -> StoreEligibility {
        try readOnWriter { context in
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard item.household != nil else { return .needsStore }
            if item.anyStore { return .anyStore }
            let active = (item.stores ?? []).filter { !$0.isArchived }.sorted(by: Self.storeDisplayOrder)
            return active.isEmpty ? .needsStore : .activeStores(active.map(\.id))
        }
    }

    static func storeDisplayOrder(_ lhs: Store, _ rhs: Store) -> Bool {
        ordered(lhsOrder: lhs.displayOrder, lhsID: lhs.id, rhsOrder: rhs.displayOrder, rhsID: rhs.id)
    }

    static func categoryDisplayOrder(_ lhs: Category, _ rhs: Category) -> Bool {
        ordered(lhsOrder: lhs.displayOrder, lhsID: lhs.id, rhsOrder: rhs.displayOrder, rhsID: rhs.id)
    }

    private static func ordered(lhsOrder: Int64, lhsID: UUID, rhsOrder: Int64, rhsID: UUID) -> Bool {
        lhsOrder == rhsOrder ? lhsID.uuidString < rhsID.uuidString : lhsOrder < rhsOrder
    }

    @discardableResult
    func addRememberedNeed(itemID: UUID, listID: UUID) throws -> UUID {
        try write { context in
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard let list = try self.list(id: listID, in: context) else {
                throw NeedServiceError.listNotFound
            }
            guard let household = item.household,
                  list.household == household,
                  item.objectID.persistentStore == list.objectID.persistentStore else {
                throw NeedServiceError.scopeChanged
            }
            let request = Need.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(
                format: "item.id == %@ AND list.id == %@ AND archived == NO",
                itemID as CVarArg,
                listID as CVarArg
            )
            if let existing = try context.fetch(request).first {
                existing.revision += 1
                return existing.id
            }
            let need = self.makeNeed(title: item.name, list: list, context: context)
            need.item = item
            return need.id
        }
    }

    @discardableResult
    func addOneTimeNeed(title: String, listID: UUID) throws -> UUID {
        try write { context in
            guard let list = try self.list(id: listID, in: context) else {
                throw NeedServiceError.listNotFound
            }
            guard list.household != nil else {
                throw NeedServiceError.scopeChanged
            }
            return self.makeNeed(title: title, list: list, context: context).id
        }
    }

    func setCarted(_ carted: Bool, needID: UUID) throws {
        try editNeed(id: needID) { $0.carted = carted }
    }

    func setQuantity(_ quantity: Int64, needID: UUID) throws {
        guard quantity > 0 else {
            throw NeedServiceError.invalidQuantity
        }
        try editNeed(id: needID) { $0.quantity = quantity }
    }

    func captureCarted(householdID: UUID, listID: UUID) throws -> ClearCartedToken {
        try readOnWriter { context in
            guard let list = try self.list(id: listID, in: context),
                  list.household?.id == householdID else {
                throw NeedServiceError.scopeChanged
            }
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(
                format: "list.id == %@ AND carted == YES AND archived == NO",
                listID as CVarArg
            )
            let snapshot = Dictionary(uniqueKeysWithValues: try context.fetch(request).map { ($0.id, $0.revision) })
            return ClearCartedToken(
                id: UUID(),
                householdID: householdID,
                listID: listID,
                revisionsByNeedID: snapshot
            )
        }
    }

    @discardableResult
    func clearCarted(using token: ClearCartedToken) throws -> Int {
        try write { context in
            guard let household = try self.household(id: token.householdID, in: context),
                  let list = try self.list(id: token.listID, in: context),
                  list.household == household else {
                throw NeedServiceError.scopeChanged
            }
            let existingRequest = ClearOperation.fetchRequest()
            existingRequest.fetchLimit = 1
            existingRequest.predicate = NSPredicate(format: "id == %@", token.id as CVarArg)
            if try context.fetch(existingRequest).first != nil {
                return 0
            }
            let operation: ClearOperation = self.insert("ClearOperation", in: context)
            operation.id = token.id
            operation.createdAt = Date()
            operation.snapshot = try self.encoder.encode(token)
            self.route(operation, with: household, in: context)
            operation.household = household
            operation.list = list

            var count = 0
            for (needID, capturedRevision) in token.revisionsByNeedID {
                guard let need = try self.need(id: needID, in: context),
                      need.list == list,
                      need.carted,
                      !need.archived,
                      need.revision == capturedRevision else {
                    continue
                }
                need.archived = true
                need.clearOperationID = token.id
                need.revision += 1
                count += 1
            }
            return count
        }
    }

    @discardableResult
    func undoClear(operationID: UUID) throws -> Int {
        try write { context in
            let operationRequest = ClearOperation.fetchRequest()
            operationRequest.fetchLimit = 1
            operationRequest.predicate = NSPredicate(format: "id == %@", operationID as CVarArg)
            guard let operation = try context.fetch(operationRequest).first else { return 0 }
            let token = try self.decoder.decode(ClearCartedToken.self, from: operation.snapshot)
            guard operation.household?.id == token.householdID,
                  operation.list?.id == token.listID else {
                throw NeedServiceError.scopeChanged
            }

            var count = 0
            for (needID, capturedRevision) in token.revisionsByNeedID {
                guard let need = try self.need(id: needID, in: context),
                      need.archived,
                      need.clearOperationID == operationID,
                      need.revision == capturedRevision + 1,
                      need.list?.id == token.listID,
                      need.list?.household?.id == token.householdID else {
                    continue
                }
                if let itemID = need.item?.id,
                   try self.hasActiveRememberedNeed(itemID: itemID, listID: token.listID, excluding: need.id, in: context) {
                    continue
                }
                need.archived = false
                need.clearOperationID = nil
                need.revision += 1
                count += 1
            }
            return count
        }
    }

    private func editNeed(id: UUID, change: @escaping (Need) -> Void) throws {
        try write { context in
            guard let need = try self.need(id: id, in: context) else {
                throw NeedServiceError.needNotFound
            }
            guard !need.archived else {
                throw NeedServiceError.scopeChanged
            }
            change(need)
            need.revision += 1
            need.clearOperationID = nil
        }
    }

    private func makeNeed(title: String, list: GroceryList, context: NSManagedObjectContext) -> Need {
        let need: Need = insert("Need", in: context)
        need.id = UUID()
        need.title = title
        need.quantity = 1
        need.carted = false
        need.urgency = "normal"
        need.revision = 0
        need.archived = false
        if let store = list.objectID.persistentStore {
            context.assign(need, to: store)
        }
        need.list = list
        return need
    }

    private func household(id: UUID, in context: NSManagedObjectContext) throws -> Household? {
        try fetch(id: id, request: Household.fetchRequest(), in: context)
    }

    private func list(id: UUID, in context: NSManagedObjectContext) throws -> GroceryList? {
        try fetch(id: id, request: GroceryList.fetchRequest(), in: context)
    }

    private func item(id: UUID, in context: NSManagedObjectContext) throws -> Item? {
        try fetch(id: id, request: Item.fetchRequest(), in: context)
    }

    private func store(id: UUID, in context: NSManagedObjectContext) throws -> Store? {
        try fetch(id: id, request: Store.fetchRequest(), in: context)
    }

    private func category(id: UUID, in context: NSManagedObjectContext) throws -> Category? {
        try fetch(id: id, request: Category.fetchRequest(), in: context)
    }

    private func validatedName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NeedServiceError.invalidName }
        return trimmed
    }

    private func need(id: UUID, in context: NSManagedObjectContext) throws -> Need? {
        try fetch(id: id, request: Need.fetchRequest(), in: context)
    }

    private func fetch<T: NSManagedObject>(
        id: UUID,
        request: NSFetchRequest<T>,
        in context: NSManagedObjectContext
    ) throws -> T? {
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).first
    }

    private func hasActiveRememberedNeed(
        itemID: UUID,
        listID: UUID,
        excluding needID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        let request = Need.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(
            format: "item.id == %@ AND list.id == %@ AND id != %@ AND archived == NO",
            itemID as CVarArg,
            listID as CVarArg,
            needID as CVarArg
        )
        return try !context.fetch(request).isEmpty
    }

    private func insert<T: NSManagedObject>(_ entityName: String, in context: NSManagedObjectContext) -> T {
        NSEntityDescription.insertNewObject(forEntityName: entityName, into: context) as! T
    }

    private func route(_ object: NSManagedObject, with household: Household, in context: NSManagedObjectContext) {
        guard let store = household.objectID.persistentStore else { return }
        context.assign(object, to: store)
    }

    private func readOnWriter<T>(_ body: @escaping (NSManagedObjectContext) throws -> T) throws -> T {
        var result: Result<T, Error>!
        persistence.writer.performAndWait {
            self.persistence.writer.reset()
            result = Result { try body(self.persistence.writer) }
        }
        return try result.get()
    }

    private func write<T>(_ body: @escaping (NSManagedObjectContext) throws -> T) throws -> T {
        var result: Result<T, Error>!
        persistence.writer.performAndWait {
            self.persistence.writer.reset()
            result = Result {
                do {
                    let value = try body(self.persistence.writer)
                    if self.persistence.writer.hasChanges {
                        try self.persistence.writer.save()
                    }
                    return value
                } catch {
                    self.persistence.writer.rollback()
                    throw error
                }
            }
        }
        return try result.get()
    }
}
