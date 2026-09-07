import CoreData

struct ClearCartedToken: Codable, Equatable {
    let id: UUID
    let householdID: UUID
    let listID: UUID
    let revisionsByNeedID: [UUID: Int64]
}

struct ClearCartedPreview: Equatable {
    let token: ClearCartedToken
    let rows: [ClearCartedPreviewRow]
}

struct ClearCartedPreviewRow: Equatable {
    let needID: UUID
    let revision: Int64
    let title: String
    let quantity: Int64?
    let oneTime: Bool
}

enum NeedUrgency: String, Codable, CaseIterable {
    case normal
    case urgent
}

enum NeedKind: String, Codable {
    case remembered
    case oneTime
}

struct RememberedDuplicateGroup: Equatable {
    let itemID: UUID
    let candidates: [RememberedDuplicateCandidate]
}

struct RememberedDuplicateCandidate: Equatable {
    let needID: UUID
    let quantity: Int64?
    let carted: Bool
    let urgency: NeedUrgency
    let notes: String
    let revision: Int64
}

enum NeedServiceError: Error, Equatable {
    case householdNotFound
    case listNotFound
    case itemNotFound
    case itemArchived
    case needNotFound
    case storeNotFound
    case categoryNotFound
    case scopeChanged
    case invalidQuantity
    case invalidName
    case catalogNameCollision([UUID])
    case activeRememberedNeedConflict(UUID)
    case activeRememberedNeedDuplicates(RememberedDuplicateGroup)
    case invalidOccurrenceIdentity
    case invalidCatalogIdentity
    case invalidStoreIdentity
    case invalidClearOperationIdentity
    case incompleteRecoveryData
}

enum StoreEligibility: Equatable {
    case anyStore
    case activeStores([UUID])
    case needsStore
}

enum StoreRemovalAction: Equatable {
    case delete
    case archive
}

enum CatalogRemovalAction: Equatable {
    case delete
    case archive
    case keepArchived
}

struct CatalogItemValues: Equatable {
    var name: String
    var notes: String
    var categoryID: UUID?
    var anyStore: Bool
    var storeIDs: Set<UUID>
}

struct CatalogRemovalPreview: Equatable {
    let action: CatalogRemovalAction
    let values: CatalogItemValues
    let isArchived: Bool
}

struct RememberedNeedValues: Equatable {
    var quantity: Int64? = nil
    var purchaseNotes: String = ""
    var urgency: NeedUrgency = .normal
}

struct CreatedRememberedGrocery: Equatable {
    let itemID: UUID
    let needID: UUID
}

private struct ValidatedCatalogItemValues {
    let name: String
    let notes: String
    let category: Category?
    let stores: Set<Store>
    let anyStore: Bool
}

final class NeedService {
    private static let unsetImportedID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private let persistence: PersistenceController
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func firstHouseholdSelection() throws -> (householdID: UUID, listID: UUID)? {
        try readOnWriter { context in
            let request = Household.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            for household in try context.fetch(request) {
                guard household.id != Self.unsetImportedID,
                      let list = household.groceryList,
                      list.id != Self.unsetImportedID,
                      household.objectID.persistentStore == list.objectID.persistentStore else { continue }
                return (household.id, list.id)
            }
            return nil
        }
    }

    func isPersistentStoreEmpty() throws -> Bool {
        try readOnWriter { context in
            for entityName in ["Household", "Store", "Category", "Item", "GroceryList", "Need", "ClearOperation"] {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                request.fetchLimit = 1
                if try context.count(for: request) > 0 { return false }
            }
            return true
        }
    }

    @discardableResult
    func createHousehold(name: String = "Household") throws -> (householdID: UUID, listID: UUID) {
        let name = try validatedName(name)
        return try write { context in
            let household: Household = self.insert("Household", in: context)
            household.id = UUID()
            household.name = name
            if let store = self.persistence.primaryStore {
                context.assign(household, to: store)
            }
            let list: GroceryList = self.insert("GroceryList", in: context)
            list.id = UUID()
            self.route(list, with: household, in: context)
            list.household = household
            return (household.id, list.id)
        }
    }

    @discardableResult
    func createStore(
        name: String,
        householdID: UUID,
        listID: UUID? = nil,
        displayOrder: Int64 = 0
    ) throws -> UUID {
        let name = try validatedName(name)
        return try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
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
    func createCategory(
        name: String,
        householdID: UUID,
        listID: UUID? = nil,
        displayOrder: Int64? = nil
    ) throws -> UUID {
        let name = try validatedName(name)
        return try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            let category: Category = self.insert("Category", in: context)
            category.id = UUID()
            category.name = name
            if let displayOrder {
                category.displayOrder = displayOrder
            } else {
                let currentMaximum = household.categories?.map(\.displayOrder).max() ?? -1
                category.displayOrder = currentMaximum == Int64.max ? Int64.max : currentMaximum + 1
            }
            self.route(category, with: household, in: context)
            category.household = household
            return category.id
        }
    }

    func renameCategory(
        name: String,
        categoryID: UUID,
        householdID: UUID,
        listID: UUID? = nil
    ) throws {
        let name = try validatedName(name)
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            guard let category = try self.category(id: categoryID, in: context) else {
                throw NeedServiceError.categoryNotFound
            }
            guard category.household == household,
                  category.objectID.persistentStore == household.objectID.persistentStore else {
                throw NeedServiceError.scopeChanged
            }
            category.name = name
        }
    }

    func reorderCategories(
        _ orderedCategoryIDs: [UUID],
        householdID: UUID,
        listID: UUID? = nil
    ) throws {
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            let request = Category.fetchRequest()
            let owned = try context.fetch(request).filter {
                $0.household == household &&
                    $0.objectID.persistentStore == household.objectID.persistentStore
            }
            let ownedIDs = owned.map(\.id)
            guard !ownedIDs.contains(PersistenceModel.unsetID),
                  Set(ownedIDs).count == owned.count,
                  Set(orderedCategoryIDs).count == orderedCategoryIDs.count,
                  Set(ownedIDs) == Set(orderedCategoryIDs) else {
                throw NeedServiceError.scopeChanged
            }
            for category in owned {
                guard let canonical = try self.category(id: category.id, in: context), canonical === category else {
                    throw NeedServiceError.scopeChanged
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: owned.map { ($0.id, $0) })
            for (index, id) in orderedCategoryIDs.enumerated() {
                byID[id]?.displayOrder = Int64(index)
            }
        }
    }

    func setStoreArchived(
        _ archived: Bool,
        storeID: UUID,
        householdID: UUID,
        listID: UUID? = nil
    ) throws {
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            guard let store = try self.store(id: storeID, in: context) else {
                throw NeedServiceError.storeNotFound
            }
            guard store.household == household,
                  store.objectID.persistentStore == household.objectID.persistentStore else {
                throw NeedServiceError.scopeChanged
            }
            store.isArchived = archived
        }
    }

    func renameStore(
        name: String,
        storeID: UUID,
        householdID: UUID,
        listID: UUID? = nil
    ) throws {
        let name = try validatedName(name)
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            guard let store = try self.store(id: storeID, in: context) else { throw NeedServiceError.storeNotFound }
            guard store.household == household,
                  store.objectID.persistentStore == household.objectID.persistentStore else { throw NeedServiceError.scopeChanged }
            store.name = name
        }
    }

    func reorderStores(
        _ orderedStoreIDs: [UUID],
        householdID: UUID,
        listID: UUID? = nil
    ) throws {
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            let request = Store.fetchRequest()
            let owned = try context.fetch(request).filter {
                !$0.isArchived && $0.household == household &&
                    $0.objectID.persistentStore == household.objectID.persistentStore
            }
            let ownedIDs = owned.map(\.id)
            guard !ownedIDs.contains(PersistenceModel.unsetID),
                  Set(ownedIDs).count == owned.count,
                  Set(orderedStoreIDs).count == orderedStoreIDs.count,
                  Set(owned.map(\.id)) == Set(orderedStoreIDs) else { throw NeedServiceError.scopeChanged }
            for store in owned {
                guard let canonical = try self.store(id: store.id, in: context), canonical === store else {
                    throw NeedServiceError.scopeChanged
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: owned.map { ($0.id, $0) })
            for (index, id) in orderedStoreIDs.enumerated() { byID[id]?.displayOrder = Int64(index) }
        }
    }

    func storeRemovalAction(
        storeID: UUID,
        householdID: UUID,
        listID: UUID
    ) throws -> StoreRemovalAction {
        try readOnWriter { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            let store = try self.validatedStoreForManagement(
                storeID: storeID, household: household, in: context
            )
            return self.storeHasReferences(store) ? .archive : .delete
        }
    }

    @discardableResult
    func removeStore(
        storeID: UUID,
        householdID: UUID,
        listID: UUID,
        confirmedAction: StoreRemovalAction? = nil
    ) throws -> StoreRemovalAction {
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            let store = try self.validatedStoreForManagement(
                storeID: storeID, household: household, in: context
            )
            if confirmedAction == .archive || self.storeHasReferences(store) {
                store.isArchived = true
                return .archive
            }
            context.delete(store)
            return .delete
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

    func removeCategory(
        categoryID: UUID,
        householdID: UUID,
        listID: UUID? = nil
    ) throws {
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            guard let category = try self.category(id: categoryID, in: context) else {
                throw NeedServiceError.categoryNotFound
            }
            guard category.household == household,
                  category.objectID.persistentStore == household.objectID.persistentStore else {
                throw NeedServiceError.scopeChanged
            }
            for item in category.items ?? [] { item.category = nil }
            for need in category.oneTimeNeeds ?? [] {
                need.oneTimeCategory = nil
                if !need.archived {
                    let (revision, overflow) = need.revision.addingReportingOverflow(1)
                    guard !overflow else { throw NeedServiceError.scopeChanged }
                    need.revision = revision
                    need.clearOperationID = nil
                }
            }
            context.delete(category)
        }
    }

    @discardableResult
    func createItem(
        name: String,
        notes: String = "",
        categoryID: UUID? = nil,
        storeIDs: Set<UUID> = [],
        householdID: UUID,
        anyStore: Bool = true
    ) throws -> UUID {
        let name = try validatedName(name)
        return try write { context in
            guard let household = try self.household(id: householdID, in: context) else {
                throw NeedServiceError.householdNotFound
            }
            let stores = try self.validatedStores(
                ids: storeIDs,
                household: household,
                requiringActiveStoreUnless: anyStore,
                in: context
            )
            let category = try self.validatedCategory(id: categoryID, household: household, in: context)
            let item: Item = self.insert("Item", in: context)
            item.id = UUID()
            item.name = name
            item.notes = self.trimmedNotes(notes)
            item.anyStore = anyStore
            item.isArchived = false
            self.route(item, with: household, in: context)
            item.household = household
            item.category = category
            item.stores = stores
            return item.id
        }
    }

    @discardableResult
    func createCatalogItem(
        values: CatalogItemValues,
        householdID: UUID,
        listID: UUID? = nil,
        allowingNameCollision: Bool = false
    ) throws -> UUID {
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            let validated = try self.validatedCatalogValues(values, household: household, in: context)
            let collisions = try self.catalogNameCollisions(
                name: validated.name,
                household: household,
                excluding: nil,
                in: context
            )
            if !allowingNameCollision {
                guard collisions.isEmpty else { throw NeedServiceError.catalogNameCollision(collisions) }
            }
            let item = self.insertCatalogItem(validated, household: household, in: context)
            return item.id
        }
    }

    func saveCatalogItem(
        itemID: UUID,
        householdID: UUID,
        listID: UUID? = nil,
        values: CatalogItemValues,
        allowingNameCollision: Bool = false
    ) throws {
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            try self.validate(item: item, belongsTo: household)
            let validated = try self.validatedCatalogValues(values, household: household, in: context)
            let normalizedNameChanged = CatalogProjection.normalizedName(item.name) !=
                CatalogProjection.normalizedName(validated.name)
            if normalizedNameChanged {
                let collisions = try self.catalogNameCollisions(
                    name: validated.name,
                    household: household,
                    excluding: item.id,
                    in: context
                )
                if !allowingNameCollision && !collisions.isEmpty {
                    throw NeedServiceError.catalogNameCollision(collisions)
                }
            }
            item.name = validated.name
            item.notes = validated.notes
            item.category = validated.category
            item.anyStore = values.anyStore
            item.stores = validated.stores
        }
    }

    func setCatalogItemArchived(
        itemID: UUID,
        householdID: UUID,
        listID: UUID? = nil,
        archived: Bool
    ) throws {
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            try self.validate(item: item, belongsTo: household)
            item.isArchived = archived
        }
    }

    func catalogItemRemovalPreview(
        itemID: UUID,
        householdID: UUID,
        listID: UUID
    ) throws -> CatalogRemovalPreview {
        try readOnWriter { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            try self.validate(item: item, belongsTo: household)
            let hasReferences = self.catalogItemHasReferences(item)
            let action: CatalogRemovalAction = hasReferences
                ? (item.isArchived ? .keepArchived : .archive)
                : .delete
            return CatalogRemovalPreview(
                action: action,
                values: self.catalogValues(for: item),
                isArchived: item.isArchived
            )
        }
    }

    @discardableResult
    func removeCatalogItem(
        itemID: UUID,
        householdID: UUID,
        listID: UUID,
        preview: CatalogRemovalPreview
    ) throws -> CatalogRemovalAction {
        try write { context in
            let household = try self.validatedCommandHousehold(
                householdID: householdID, listID: listID, in: context
            )
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            try self.validate(item: item, belongsTo: household)
            guard self.catalogValues(for: item) == preview.values,
                  item.isArchived == preview.isArchived else {
                throw NeedServiceError.scopeChanged
            }
            if preview.action == .archive || self.catalogItemHasReferences(item) {
                item.isArchived = true
                return .archive
            }
            guard preview.action == .delete else { return .keepArchived }
            context.delete(item)
            return .delete
        }
    }

    func createRememberedGrocery(
        householdID: UUID,
        listID: UUID,
        catalog: CatalogItemValues,
        need: RememberedNeedValues = RememberedNeedValues(),
        allowingCatalogNameCollision: Bool = false
    ) throws -> CreatedRememberedGrocery {
        try validate(needValues: need)
        return try write { context in
            guard let household = try self.household(id: householdID, in: context) else {
                throw NeedServiceError.householdNotFound
            }
            guard let list = try self.list(id: listID, in: context) else {
                throw NeedServiceError.listNotFound
            }
            try self.validate(list: list, belongsTo: household)
            let validatedCatalog = try self.validatedCatalogValues(catalog, household: household, in: context)
            let collisions = try self.catalogNameCollisions(
                name: validatedCatalog.name, household: household, excluding: nil, in: context
            )
            if !allowingCatalogNameCollision && !collisions.isEmpty {
                throw NeedServiceError.catalogNameCollision(collisions)
            }
            let item = self.insertCatalogItem(validatedCatalog, household: household, in: context)
            let newNeed = self.insertRememberedNeed(item: item, list: list, values: need, in: context)
            return CreatedRememberedGrocery(itemID: item.id, needID: newNeed.id)
        }
    }

    func saveRememberedGrocery(
        needID: UUID,
        householdID: UUID,
        listID: UUID,
        catalog: CatalogItemValues,
        need values: RememberedNeedValues,
        allowingCatalogNameCollision: Bool = false
    ) throws {
        try validate(needValues: values)
        try write { context in
            let resolved = try self.validatedActiveNeed(
                needID: needID, householdID: householdID, listID: listID, in: context
            )
            guard resolved.need.kind == NeedKind.remembered.rawValue,
                  let item = resolved.need.item else { throw NeedServiceError.scopeChanged }
            guard item.id != PersistenceModel.unsetID,
                  let canonicalItem = try self.item(id: item.id, in: context),
                  canonicalItem === item else {
                throw NeedServiceError.invalidCatalogIdentity
            }
            try self.validate(item: item, belongsTo: resolved.household)
            let active = try self.activeRememberedNeeds(itemID: item.id, listID: listID, in: context)
            guard active.count == 1, active[0] === resolved.need else {
                if active.count > 1 {
                    throw NeedServiceError.activeRememberedNeedDuplicates(
                        try self.duplicateGroup(itemID: item.id, needs: active)
                    )
                }
                throw NeedServiceError.scopeChanged
            }
            let validatedCatalog = try self.validatedCatalogValues(
                catalog, household: resolved.household, in: context
            )
            let normalizedNameChanged = CatalogProjection.normalizedName(item.name) !=
                CatalogProjection.normalizedName(validatedCatalog.name)
            if normalizedNameChanged {
                let collisions = try self.catalogNameCollisions(
                    name: validatedCatalog.name,
                    household: resolved.household,
                    excluding: item.id,
                    in: context
                )
                if !allowingCatalogNameCollision && !collisions.isEmpty {
                    throw NeedServiceError.catalogNameCollision(collisions)
                }
            }
            item.name = validatedCatalog.name
            item.notes = validatedCatalog.notes
            item.category = validatedCatalog.category
            item.anyStore = validatedCatalog.anyStore
            item.stores = validatedCatalog.stores
            resolved.need.title = validatedCatalog.name
            try self.apply(values, to: resolved.need)
        }
    }

    func saveOneTimeGrocery(
        needID: UUID,
        householdID: UUID,
        listID: UUID,
        title: String,
        categoryID: UUID?,
        storeIDs: Set<UUID>,
        anyStore: Bool,
        need values: RememberedNeedValues
    ) throws {
        let title = try validatedName(title)
        try validate(needValues: values)
        try write { context in
            let resolved = try self.validatedActiveNeed(
                needID: needID, householdID: householdID, listID: listID, in: context
            )
            guard resolved.need.kind == NeedKind.oneTime.rawValue,
                  resolved.need.item == nil else { throw NeedServiceError.scopeChanged }
            let stores = try self.validatedStores(
                ids: storeIDs,
                household: resolved.household,
                requiringActiveStoreUnless: anyStore,
                in: context
            )
            let category = try self.validatedCategory(
                id: categoryID, household: resolved.household, in: context
            )
            resolved.need.title = title
            resolved.need.oneTimeCategory = category
            resolved.need.oneTimeStores = stores
            resolved.need.oneTimeAnyStore = anyStore
            try self.apply(values, to: resolved.need)
        }
    }

    func removeNeed(
        needID: UUID,
        householdID: UUID,
        listID: UUID,
        expectedRevision: Int64
    ) throws -> UUID {
        try write { context in
            let resolved = try self.validatedActiveNeed(
                needID: needID, householdID: householdID, listID: listID, in: context
            )
            guard resolved.need.revision == expectedRevision else { throw NeedServiceError.scopeChanged }
            let (archivedRevision, archiveOverflow) = expectedRevision.addingReportingOverflow(1)
            let (_, restoreOverflow) = archivedRevision.addingReportingOverflow(1)
            guard !archiveOverflow, !restoreOverflow else { throw NeedServiceError.scopeChanged }
            let operationID = UUID()
            let token = ClearCartedToken(
                id: operationID,
                householdID: householdID,
                listID: listID,
                revisionsByNeedID: [needID: expectedRevision]
            )
            let operation: ClearOperation = self.insert("ClearOperation", in: context)
            operation.id = operationID
            operation.createdAt = Date()
            operation.snapshot = try self.encoder.encode(token)
            self.route(operation, with: resolved.household, in: context)
            operation.household = resolved.household
            operation.list = resolved.list
            resolved.need.archived = true
            resolved.need.clearOperationID = operationID
            resolved.need.revision = archivedRevision
            return operationID
        }
    }

    func uncartNeed(needID: UUID, householdID: UUID, listID: UUID) throws {
        try write { context in
            let resolved = try self.validatedActiveNeed(
                needID: needID, householdID: householdID, listID: listID, in: context
            )
            guard resolved.need.kind == NeedKind.oneTime.rawValue,
                  resolved.need.item == nil,
                  resolved.need.carted else {
                throw NeedServiceError.scopeChanged
            }
            let (nextRevision, overflow) = resolved.need.revision.addingReportingOverflow(1)
            guard !overflow else { throw NeedServiceError.scopeChanged }
            resolved.need.carted = false
            resolved.need.clearOperationID = nil
            resolved.need.revision = nextRevision
        }
    }

    func setStoreTags(itemID: UUID, storeIDs: Set<UUID>) throws {
        try setPurchaseRules(itemID: itemID, anyStore: nil, storeIDs: storeIDs)
    }

    func setPurchaseRules(itemID: UUID, anyStore: Bool?, storeIDs: Set<UUID>) throws {
        try write { context in
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard let itemHousehold = item.household else {
                throw NeedServiceError.scopeChanged
            }
            let resolvedAnyStore = anyStore ?? item.anyStore
            let stores = try self.validatedStores(
                ids: storeIDs,
                household: itemHousehold,
                requiringActiveStoreUnless: resolvedAnyStore,
                in: context
            )
            item.anyStore = resolvedAnyStore
            item.stores = stores
        }
    }

    func updateItemMetadata(
        itemID: UUID,
        householdID: UUID,
        name: String,
        notes: String,
        categoryID: UUID?,
        isArchived: Bool
    ) throws {
        let name = try validatedName(name)
        try write { context in
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard let household = item.household, household.id == householdID else {
                throw NeedServiceError.scopeChanged
            }
            item.name = name
            item.notes = self.trimmedNotes(notes)
            item.category = try self.validatedCategory(id: categoryID, household: household, in: context)
            item.isArchived = isArchived
        }
    }

    func catalogSuggestionNames(householdID: UUID) throws -> [String] {
        try readOnWriter { context in
            guard try self.household(id: householdID, in: context) != nil else {
                throw NeedServiceError.householdNotFound
            }
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(format: "household.id == %@", householdID as CVarArg)
            let items = try self.validCatalogItems(try context.fetch(request))
            return CatalogProjection.suggestionNames(
                from: items.map { ($0.name, $0.isArchived) }
            )
        }
    }

    func allCatalogItemIDs(householdID: UUID) throws -> Set<UUID> {
        try readOnWriter { context in
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(
                format: "household.id == %@",
                householdID as CVarArg
            )
            return Set(try self.validCatalogItems(try context.fetch(request)).filter { !$0.isArchived }.map(\.id))
        }
    }

    func allActiveNeedIDs(householdID: UUID) throws -> Set<UUID> {
        try readOnWriter { context in
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(
                format: "list.household.id == %@ AND archived == NO",
                householdID as CVarArg
            )
            let needs = try context.fetch(request)
            try self.validateOccurrenceIdentities(needs)
            return Set(needs.map(\.id))
        }
    }

    func filteredCatalogItemIDs(
        householdID: UUID,
        filter: CatalogItemFilter,
        includeArchived: Bool = false
    ) throws -> [UUID] {
        try readOnWriter { context in
            guard let household = try self.household(id: householdID, in: context) else {
                throw NeedServiceError.householdNotFound
            }
            let activeStores = try self.activeStoreIDs(household: household, in: context)
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(
                format: "household.id == %@",
                householdID as CVarArg
            )
            let items = try self.validCatalogItems(try context.fetch(request)).filter {
                $0.household == household &&
                    $0.objectID.persistentStore == household.objectID.persistentStore
            }
            return items.filter { item in
                guard includeArchived || !item.isArchived else { return false }
                let value = PurchaseRuleValue(
                    explicitStoreIDs: Set(item.stores?.map(\.id) ?? []),
                    anyStore: item.anyStore
                )
                return filter.purchase.matches(value, activeStoreIDs: activeStores) &&
                    CatalogProjection.textMatches(item.name, query: filter.text) &&
                    (filter.categoryID == nil || item.category?.id == filter.categoryID)
            }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        }
    }

    func filteredActiveNeedIDs(householdID: UUID, filter: GroceryNeedFilter) throws -> [UUID] {
        try readOnWriter { context in
            let activeStores = try self.activeStoreIDs(householdID: householdID, in: context)
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(
                format: "list.household.id == %@ AND archived == NO",
                householdID as CVarArg
            )
            let activeNeeds = try context.fetch(request)
            try self.validateOccurrenceIdentities(activeNeeds)
            return activeNeeds.filter { need in
                let item = need.item
                let isOneTime = need.kind == NeedKind.oneTime.rawValue
                let resolvedItem = item.flatMap { candidate -> Item? in
                    guard candidate.id != PersistenceModel.unsetID,
                          candidate.household == need.list?.household,
                          candidate.objectID.persistentStore == need.objectID.persistentStore,
                          (try? self.item(id: candidate.id, in: context)) === candidate else { return nil }
                    return candidate
                }
                let value = PurchaseRuleValue(
                    explicitStoreIDs: item.map { Set($0.stores?.map(\.id) ?? []) }
                        ?? (isOneTime ? Set(need.oneTimeStores?.map(\.id) ?? []) : []),
                    anyStore: item?.anyStore ?? (isOneTime && need.oneTimeAnyStore),
                    hasResolvedIdentity: resolvedItem != nil || (item == nil && isOneTime)
                )
                return filter.purchase.matches(value, activeStoreIDs: activeStores) &&
                    CatalogProjection.textMatches(item?.name ?? need.title, query: filter.text) &&
                    (filter.categoryID == nil || (item?.category ?? (isOneTime ? need.oneTimeCategory : nil))?.id == filter.categoryID) &&
                    (filter.carted == nil || need.carted == filter.carted) &&
                    (filter.urgency == nil || need.urgency == filter.urgency)
            }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        }
    }

    func storeEligibility(itemID: UUID) throws -> StoreEligibility {
        try readOnWriter { context in
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard item.household != nil else { return .needsStore }
            if item.anyStore || (item.stores ?? []).isEmpty { return .anyStore }
            let active = try self.validActiveStores(
                Array(item.stores ?? [])
            ).filter {
                !$0.isArchived && $0.household != nil && $0.household == item.household &&
                    $0.objectID.persistentStore == item.objectID.persistentStore
            }.sorted(by: Self.storeDisplayOrder)
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
    func activeRememberedNeedID(itemID: UUID, listID: UUID) throws -> UUID? {
        try readOnWriter { context in
            guard let item = try self.item(id: itemID, in: context) else { throw NeedServiceError.itemNotFound }
            guard let list = try self.list(id: listID, in: context) else { throw NeedServiceError.listNotFound }
            guard item.household == list.household else { throw NeedServiceError.scopeChanged }
            let active = try self.activeRememberedNeeds(itemID: itemID, listID: listID, in: context)
            guard active.count < 2 else {
                throw NeedServiceError.activeRememberedNeedDuplicates(try self.duplicateGroup(itemID: itemID, needs: active))
            }
            return active.first?.id
        }
    }

    func addRememberedNeed(
        itemID: UUID,
        listID: UUID,
        householdID: UUID? = nil,
        quantity: Int64? = nil,
        notes: String? = nil,
        urgency: NeedUrgency = .normal
    ) throws -> UUID {
        if let quantity, !(1...99).contains(quantity) { throw NeedServiceError.invalidQuantity }
        return try write { context in
            guard let item = try self.item(id: itemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard let list = try self.list(id: listID, in: context) else {
                throw NeedServiceError.listNotFound
            }
            if let householdID {
                guard let expectedHousehold = try self.household(id: householdID, in: context),
                      list.household == expectedHousehold,
                      item.household == expectedHousehold else {
                    throw NeedServiceError.scopeChanged
                }
            }
            guard let household = item.household,
                  list.household == household,
                  item.objectID.persistentStore == list.objectID.persistentStore else {
                throw NeedServiceError.scopeChanged
            }
            let active = try self.activeRememberedNeeds(itemID: itemID, listID: listID, in: context)
            if let existing = active.first {
                guard active.count == 1 else {
                    throw NeedServiceError.activeRememberedNeedDuplicates(try self.duplicateGroup(itemID: itemID, needs: active))
                }
                let (nextRevision, overflow) = existing.revision.addingReportingOverflow(1)
                guard !overflow else { throw NeedServiceError.scopeChanged }
                if let quantity { existing.quantity = quantity }
                if let notes { existing.notes = self.trimmedNotes(notes) }
                existing.carted = false
                existing.urgency = urgency.rawValue
                existing.clearOperationID = nil
                existing.revision = nextRevision
                return existing.id
            }
            guard !item.isArchived else {
                throw NeedServiceError.itemArchived
            }
            let need = self.makeNeed(title: item.name, list: list, context: context)
            need.kind = NeedKind.remembered.rawValue
            need.item = item
            need.quantity = quantity
            need.notes = notes.map(self.trimmedNotes) ?? ""
            need.urgency = urgency.rawValue
            return need.id
        }
    }

    @discardableResult
    func addOneTimeNeed(
        title: String,
        notes: String = "",
        categoryID: UUID? = nil,
        storeIDs: Set<UUID> = [],
        anyStore: Bool = true,
        quantity: Int64? = nil,
        urgency: NeedUrgency = .normal,
        householdID: UUID? = nil,
        listID: UUID
    ) throws -> UUID {
        let title = try validatedName(title)
        if let quantity, !(1...99).contains(quantity) { throw NeedServiceError.invalidQuantity }
        return try write { context in
            guard let list = try self.list(id: listID, in: context) else {
                throw NeedServiceError.listNotFound
            }
            guard let household = list.household else {
                throw NeedServiceError.scopeChanged
            }
            if let householdID {
                guard let expectedHousehold = try self.household(id: householdID, in: context),
                      household == expectedHousehold else { throw NeedServiceError.scopeChanged }
            }
            let stores = try self.validatedStores(
                ids: storeIDs,
                household: household,
                requiringActiveStoreUnless: anyStore,
                in: context
            )
            let category = try self.validatedCategory(id: categoryID, household: household, in: context)
            let need = self.makeNeed(title: title, list: list, context: context)
            need.kind = NeedKind.oneTime.rawValue
            need.notes = self.trimmedNotes(notes)
            need.quantity = quantity
            need.urgency = urgency.rawValue
            need.oneTimeAnyStore = anyStore
            need.oneTimeCategory = category
            need.oneTimeStores = stores
            return need.id
        }
    }

    @discardableResult
    func copyCatalogItemAsOneTimeNeed(itemID: UUID, listID: UUID) throws -> UUID {
        try write { context in
            guard let item = try self.item(id: itemID, in: context) else { throw NeedServiceError.itemNotFound }
            guard !item.isArchived else { throw NeedServiceError.itemArchived }
            guard let list = try self.list(id: listID, in: context),
                  let household = list.household,
                  item.household == household,
                  item.objectID.persistentStore == list.objectID.persistentStore else {
                throw NeedServiceError.scopeChanged
            }
            let need = self.makeNeed(title: item.name, list: list, context: context)
            need.kind = NeedKind.oneTime.rawValue
            need.notes = item.notes
            need.oneTimeAnyStore = item.anyStore
            need.oneTimeCategory = item.category
            need.oneTimeStores = item.stores
            return need.id
        }
    }

    func setCarted(_ carted: Bool, needID: UUID) throws {
        try editNeed(id: needID) { $0.carted = carted }
    }

    func setQuantity(_ quantity: Int64?, needID: UUID) throws {
        if let quantity, !(1...99).contains(quantity) {
            throw NeedServiceError.invalidQuantity
        }
        try editNeed(id: needID) { $0.quantity = quantity }
    }

    func setNeedCarted(needID: UUID, householdID: UUID, listID: UUID, carted: Bool) throws {
        try write { context in
            let resolved = try self.validatedActiveNeed(
                needID: needID, householdID: householdID, listID: listID, in: context)
            let (revision, overflow) = resolved.need.revision.addingReportingOverflow(1)
            guard !overflow else { throw NeedServiceError.scopeChanged }
            resolved.need.carted = carted
            resolved.need.clearOperationID = nil
            resolved.need.revision = revision
        }
    }

    func setNeedQuantity(needID: UUID, householdID: UUID, listID: UUID, quantity: Int64?) throws {
        if let quantity, !(1...99).contains(quantity) { throw NeedServiceError.invalidQuantity }
        try write { context in
            let resolved = try self.validatedActiveNeed(
                needID: needID, householdID: householdID, listID: listID, in: context)
            let (revision, overflow) = resolved.need.revision.addingReportingOverflow(1)
            guard !overflow else { throw NeedServiceError.scopeChanged }
            resolved.need.quantity = quantity
            resolved.need.clearOperationID = nil
            resolved.need.revision = revision
        }
    }

    func setUrgency(_ urgency: NeedUrgency, needID: UUID) throws {
        try editNeed(id: needID) { $0.urgency = urgency.rawValue }
    }

    func setPurchaseNote(_ notes: String, needID: UUID) throws {
        try editNeed(id: needID) { $0.notes = self.trimmedNotes(notes) }
    }

    func updateOneTimeNeed(
        needID: UUID,
        title: String,
        notes: String,
        categoryID: UUID?,
        storeIDs: Set<UUID>,
        anyStore: Bool
    ) throws {
        let title = try validatedName(title)
        try write { context in
            guard let need = try self.need(id: needID, in: context) else { throw NeedServiceError.needNotFound }
            guard !need.archived, need.kind == NeedKind.oneTime.rawValue, need.item == nil,
                  let household = need.list?.household else { throw NeedServiceError.scopeChanged }
            let stores = try self.validatedStores(
                ids: storeIDs, household: household, requiringActiveStoreUnless: anyStore, in: context
            )
            let category = try self.validatedCategory(id: categoryID, household: household, in: context)
            need.title = title
            need.notes = self.trimmedNotes(notes)
            need.oneTimeCategory = category
            need.oneTimeStores = stores
            need.oneTimeAnyStore = anyStore
            need.revision += 1
        }
    }

    func rememberOneTimeNeed(needID: UUID, existingItemID: UUID) throws -> UUID {
        try write { context in
            let resolved = try self.validatedOneTimeNeedInferringScope(needID: needID, in: context)
            guard let item = try self.item(id: existingItemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard !item.isArchived else { throw NeedServiceError.itemArchived }
            try self.validate(item: item, belongsTo: resolved.household)
            let conflicts = try self.activeRememberedNeeds(
                itemID: existingItemID,
                listID: resolved.list.id,
                in: context
            )
            if let conflict = conflicts.first {
                guard conflicts.count == 1 else {
                    throw NeedServiceError.activeRememberedNeedDuplicates(
                        try self.duplicateGroup(itemID: existingItemID, needs: conflicts)
                    )
                }
                throw NeedServiceError.activeRememberedNeedConflict(conflict.id)
            }
            try self.promote(
                resolved.need,
                to: item,
                values: RememberedNeedValues(
                    quantity: resolved.need.quantity,
                    purchaseNotes: resolved.need.notes,
                    urgency: NeedUrgency(rawValue: resolved.need.urgency) ?? .normal
                )
            )
            return item.id
        }
    }

    func rememberOneTimeGroceryCreatingItem(
        needID: UUID,
        householdID: UUID,
        listID: UUID,
        catalog: CatalogItemValues,
        need values: RememberedNeedValues,
        allowingCatalogNameCollision: Bool = false
    ) throws -> UUID {
        try validate(needValues: values)
        return try write { context in
            let resolved = try self.validatedActiveNeed(needID: needID, householdID: householdID, listID: listID, in: context)
            guard resolved.need.kind == NeedKind.oneTime.rawValue, resolved.need.item == nil else { throw NeedServiceError.scopeChanged }
            let validated = try self.validatedCatalogValues(catalog, household: resolved.household, in: context)
            let collisions = try self.catalogNameCollisions(name: validated.name, household: resolved.household, excluding: nil, in: context)
            guard allowingCatalogNameCollision || collisions.isEmpty else { throw NeedServiceError.catalogNameCollision(collisions) }
            let item = self.insertCatalogItem(validated, household: resolved.household, in: context)
            try self.promote(resolved.need, to: item, values: values)
            return item.id
        }
    }

    func rememberOneTimeGrocery(
        needID: UUID,
        householdID: UUID,
        listID: UUID,
        existingItemID: UUID,
        need values: RememberedNeedValues
    ) throws -> UUID {
        try validate(needValues: values)
        return try write { context in
            let resolved = try self.validatedActiveNeed(needID: needID, householdID: householdID, listID: listID, in: context)
            guard resolved.need.kind == NeedKind.oneTime.rawValue, resolved.need.item == nil else { throw NeedServiceError.scopeChanged }
            guard let item = try self.item(id: existingItemID, in: context) else { throw NeedServiceError.itemNotFound }
            try self.validate(item: item, belongsTo: resolved.household)
            guard !item.isArchived else { throw NeedServiceError.itemArchived }
            let conflicts = try self.activeRememberedNeeds(itemID: item.id, listID: listID, in: context)
            if let conflict = conflicts.first {
                guard conflicts.count == 1 else { throw NeedServiceError.activeRememberedNeedDuplicates(try self.duplicateGroup(itemID: item.id, needs: conflicts)) }
                throw NeedServiceError.activeRememberedNeedConflict(conflict.id)
            }
            try self.promote(resolved.need, to: item, values: values)
            return item.id
        }
    }

    func rememberOneTimeNeedCreatingItem(needID: UUID, itemNotes: String = "") throws -> UUID {
        try write { context in
            let resolved = try self.validatedOneTimeNeedInferringScope(needID: needID, in: context)
            let need = resolved.need
            let household = resolved.household
            let name = try self.validatedName(need.title)
            let normalized = CatalogProjection.normalizedName(name)
            let itemRequest = Item.fetchRequest()
            itemRequest.predicate = NSPredicate(format: "household.id == %@", household.id as CVarArg)
            let collisions = try context.fetch(itemRequest)
                .filter { CatalogProjection.normalizedName($0.name) == normalized }
                .map(\.id)
                .sorted { $0.uuidString < $1.uuidString }
            guard collisions.isEmpty else { throw NeedServiceError.catalogNameCollision(collisions) }
            let stores = try self.validatedStores(
                ids: Set(need.oneTimeStores?.map(\.id) ?? []),
                household: household,
                requiringActiveStoreUnless: need.oneTimeAnyStore,
                in: context
            )
            let category = try self.validatedCategory(id: need.oneTimeCategory?.id, household: household, in: context)

            let item: Item = self.insert("Item", in: context)
            item.id = UUID()
            item.name = name
            item.notes = self.trimmedNotes(itemNotes)
            item.anyStore = need.oneTimeAnyStore
            item.isArchived = false
            self.route(item, with: household, in: context)
            item.household = household
            item.category = category
            item.stores = stores
            try self.promote(
                need,
                to: item,
                values: RememberedNeedValues(
                    quantity: need.quantity,
                    purchaseNotes: need.notes,
                    urgency: NeedUrgency(rawValue: need.urgency) ?? .normal
                )
            )
            return item.id
        }
    }

    func rememberedDuplicateGroups(householdID: UUID, listID: UUID) throws -> [RememberedDuplicateGroup] {
        try readOnWriter { context in
            guard let list = try self.list(id: listID, in: context), list.household?.id == householdID else {
                throw NeedServiceError.scopeChanged
            }
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "list.id == %@ AND archived == NO AND item != nil", listID as CVarArg)
            let needs = try context.fetch(request)
            try self.validateOccurrenceIdentities(needs)
            let grouped = Dictionary(grouping: needs, by: { $0.item!.id })
            return try grouped.compactMap { itemID, needs in
                guard needs.count > 1 else { return nil }
                return try self.duplicateGroup(itemID: itemID, needs: needs)
            }.sorted { $0.itemID.uuidString < $1.itemID.uuidString }
        }
    }

    func captureCarted(
        householdID: UUID,
        listID: UUID,
        // A pre-confirmation allowlist captured by the caller (for example, visible or selected rows).
        restrictedToNeedIDs: Set<UUID>? = nil
    ) throws -> ClearCartedToken {
        try prepareClearCarted(
            householdID: householdID, listID: listID, filter: GroceryNeedFilter(carted: true),
            restrictedToNeedIDs: restrictedToNeedIDs
        ).token
    }

    func prepareCheckout(householdID: UUID, listID: UUID) throws -> ClearCartedPreview {
        try prepareClearCarted(
            householdID: householdID,
            listID: listID,
            filter: GroceryNeedFilter(carted: true)
        )
    }

    func prepareClearCarted(
        householdID: UUID,
        listID: UUID,
        filter: GroceryNeedFilter,
        restrictedToNeedIDs: Set<UUID>? = nil
    ) throws -> ClearCartedPreview {
        try readOnWriter { context in
            guard let household = try self.household(id: householdID, in: context),
                let list = try self.list(id: listID, in: context)
            else { throw NeedServiceError.scopeChanged }
            try self.validate(list: list, belongsTo: household)
            let activeStores = try self.activeStoreIDs(household: household, in: context)
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "list == %@ AND carted == YES AND archived == NO", list)
            let candidates = try context.fetch(request)
            try self.validateOccurrenceIdentities(candidates)
            let captured = try candidates.filter { need in
                guard restrictedToNeedIDs?.contains(need.id) ?? true else { return false }
                guard let canonicalNeed = try self.need(id: need.id, in: context), canonicalNeed === need
                else {
                    throw NeedServiceError.invalidOccurrenceIdentity
                }
                let item = need.item
                if let item {
                    guard let canonicalItem = try self.item(id: item.id, in: context), canonicalItem === item
                    else {
                        throw NeedServiceError.invalidCatalogIdentity
                    }
                    try self.validate(item: item, belongsTo: household)
                }
                let oneTime = need.kind == NeedKind.oneTime.rawValue
                let relatedStores = item?.stores ?? (oneTime ? need.oneTimeStores ?? [] : [])
                for store in relatedStores {
                    guard let canonicalStore = try self.store(id: store.id, in: context),
                        canonicalStore === store,
                        store.household == household,
                        store.objectID.persistentStore == household.objectID.persistentStore
                    else {
                        throw NeedServiceError.invalidStoreIdentity
                    }
                }
                let relatedCategory = item?.category ?? (oneTime ? need.oneTimeCategory : nil)
                if let category = relatedCategory {
                    guard let canonicalCategory = try self.category(id: category.id, in: context),
                        canonicalCategory === category,
                        category.household == household,
                        category.objectID.persistentStore == household.objectID.persistentStore
                    else {
                        throw NeedServiceError.categoryNotFound
                    }
                }
                let value = PurchaseRuleValue(
                    explicitStoreIDs: item.map { Set($0.stores?.map(\.id) ?? []) }
                        ?? (oneTime ? Set(need.oneTimeStores?.map(\.id) ?? []) : []),
                    anyStore: item?.anyStore ?? (oneTime && need.oneTimeAnyStore),
                    hasResolvedIdentity: item != nil || oneTime)
                return filter.purchase.matches(value, activeStoreIDs: activeStores)
                    && CatalogProjection.textMatches(item?.name ?? need.title, query: filter.text)
                    && (filter.categoryID == nil
                        || (item?.category ?? (oneTime ? need.oneTimeCategory : nil))?.id == filter.categoryID)
                    && (filter.urgency == nil || need.urgency == filter.urgency)
            }
            var snapshot: [UUID: Int64] = [:]
            for need in captured {
                guard need.id != PersistenceModel.unsetID, snapshot[need.id] == nil else {
                    throw NeedServiceError.invalidOccurrenceIdentity
                }
                snapshot[need.id] = need.revision
            }
            let token = ClearCartedToken(
                id: UUID(), householdID: householdID, listID: listID, revisionsByNeedID: snapshot)
            let rows = captured.map {
                ClearCartedPreviewRow(
                    needID: $0.id, revision: $0.revision, title: $0.item?.name ?? $0.title,
                    quantity: $0.quantity, oneTime: $0.kind == NeedKind.oneTime.rawValue)
            }.sorted { $0.needID.uuidString < $1.needID.uuidString }
            return ClearCartedPreview(token: token, rows: rows)
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
            if let existing = try self.clearOperation(id: token.id, in: context) {
                guard existing.household == household, existing.list == list else {
                    throw NeedServiceError.scopeChanged
                }
                guard let snapshot = existing.snapshot else {
                    throw NeedServiceError.incompleteRecoveryData
                }
                let existingToken = try self.decoder.decode(ClearCartedToken.self, from: snapshot)
                guard existingToken == token else { throw NeedServiceError.scopeChanged }
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
                let (archivedRevision, overflow) = need.revision.addingReportingOverflow(1)
                guard !overflow, archivedRevision < Int64.max else { continue }
                need.archived = true
                need.clearOperationID = token.id
                need.revision = archivedRevision
                count += 1
            }
            return count
        }
    }

    @discardableResult
    func undoClear(
        operationID: UUID,
        expectedHouseholdID: UUID? = nil,
        expectedListID: UUID? = nil
    ) throws -> Int {
        try write { context in
            guard let operation = try self.clearOperation(id: operationID, in: context) else { return 0 }
            if expectedHouseholdID != nil || expectedListID != nil {
                guard let expectedHouseholdID, let expectedListID,
                      let expectedHousehold = try self.household(id: expectedHouseholdID, in: context),
                      let expectedList = try self.list(id: expectedListID, in: context),
                      expectedList.household == expectedHousehold,
                      operation.household == expectedHousehold,
                      operation.list == expectedList else {
                    throw NeedServiceError.scopeChanged
                }
            }
            guard let snapshot = operation.snapshot else { throw NeedServiceError.incompleteRecoveryData }
            let token = try self.decoder.decode(ClearCartedToken.self, from: snapshot)
            guard token.id == operationID,
                  operation.household?.id == token.householdID,
                  operation.list?.id == token.listID else {
                throw NeedServiceError.scopeChanged
            }

            var count = 0
            for (needID, capturedRevision) in token.revisionsByNeedID {
                let (archivedRevision, archiveOverflow) = capturedRevision.addingReportingOverflow(1)
                let (restoredRevision, restoreOverflow) = archivedRevision.addingReportingOverflow(1)
                guard !archiveOverflow, !restoreOverflow else { continue }
                guard let need = try self.need(id: needID, in: context),
                      need.archived,
                      need.clearOperationID == operationID,
                      need.revision == archivedRevision,
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
                need.revision = restoredRevision
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
        need.kind = ""
        need.title = title
        need.notes = ""
        need.quantity = nil
        need.carted = false
        need.urgency = "normal"
        need.revision = 0
        need.archived = false
        need.oneTimeAnyStore = false
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
        try fetch(id: id, request: Item.fetchRequest(), in: context, identityError: .invalidCatalogIdentity)
    }

    private func store(id: UUID, in context: NSManagedObjectContext) throws -> Store? {
        try fetch(id: id, request: Store.fetchRequest(), in: context, identityError: .invalidStoreIdentity)
    }

    private func category(id: UUID, in context: NSManagedObjectContext) throws -> Category? {
        try fetch(id: id, request: Category.fetchRequest(), in: context)
    }

    private func validatedCategory(
        id: UUID?,
        household: Household,
        in context: NSManagedObjectContext
    ) throws -> Category? {
        guard let id else { return nil }
        guard let category = try category(id: id, in: context) else {
            throw NeedServiceError.categoryNotFound
        }
        guard category.household == household,
              category.objectID.persistentStore == household.objectID.persistentStore else {
            throw NeedServiceError.scopeChanged
        }
        return category
    }

    private func validatedStores(
        ids: Set<UUID>,
        household: Household,
        requiringActiveStoreUnless anyStore: Bool,
        in context: NSManagedObjectContext
    ) throws -> Set<Store> {
        let request = Store.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(ids))
        let stores = try context.fetch(request)
        guard stores.count == ids.count,
              stores.allSatisfy({
                  $0.household == household &&
                  $0.objectID.persistentStore == household.objectID.persistentStore
              }) else { throw NeedServiceError.scopeChanged }
        guard anyStore || ids.isEmpty || stores.contains(where: { !$0.isArchived }) else {
            throw NeedServiceError.scopeChanged
        }
        return Set(stores)
    }

    private func validatedCatalogValues(
        _ values: CatalogItemValues,
        household: Household,
        in context: NSManagedObjectContext
    ) throws -> ValidatedCatalogItemValues {
        let name = try validatedName(values.name)
        let category = try validatedCategory(id: values.categoryID, household: household, in: context)
        var stores: Set<Store> = []
        for id in values.storeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let store = try store(id: id, in: context) else {
                throw NeedServiceError.storeNotFound
            }
            guard store.household == household,
                  store.objectID.persistentStore == household.objectID.persistentStore else {
                throw NeedServiceError.scopeChanged
            }
            stores.insert(store)
        }
        guard values.anyStore || stores.isEmpty || stores.contains(where: { !$0.isArchived }) else {
            throw NeedServiceError.scopeChanged
        }
        return ValidatedCatalogItemValues(
            name: name,
            notes: trimmedNotes(values.notes),
            category: category,
            stores: stores,
            anyStore: values.anyStore || stores.isEmpty
        )
    }

    private func insertCatalogItem(
        _ values: ValidatedCatalogItemValues,
        household: Household,
        in context: NSManagedObjectContext
    ) -> Item {
        let item: Item = insert("Item", in: context)
        item.id = UUID()
        item.name = values.name
        item.notes = values.notes
        item.anyStore = values.anyStore
        item.isArchived = false
        route(item, with: household, in: context)
        item.household = household
        item.category = values.category
        item.stores = values.stores
        return item
    }

    private func catalogValues(for item: Item) -> CatalogItemValues {
        CatalogItemValues(
            name: item.name,
            notes: item.notes,
            categoryID: item.category?.id,
            anyStore: item.anyStore,
            storeIDs: Set(item.stores?.map(\.id) ?? [])
        )
    }

    private func insertRememberedNeed(
        item: Item,
        list: GroceryList,
        values: RememberedNeedValues,
        in context: NSManagedObjectContext
    ) -> Need {
        let need = makeNeed(title: item.name, list: list, context: context)
        need.kind = NeedKind.remembered.rawValue
        need.item = item
        need.quantity = values.quantity
        need.notes = trimmedNotes(values.purchaseNotes)
        need.urgency = values.urgency.rawValue
        return need
    }

    private func validate(needValues: RememberedNeedValues) throws {
        if let quantity = needValues.quantity, !(1...99).contains(quantity) {
            throw NeedServiceError.invalidQuantity
        }
    }

    private func validate(list: GroceryList, belongsTo household: Household) throws {
        guard list.household == household,
              list.objectID.persistentStore == household.objectID.persistentStore else {
            throw NeedServiceError.scopeChanged
        }
    }

    private func validatedCommandHousehold(
        householdID: UUID,
        listID: UUID?,
        in context: NSManagedObjectContext
    ) throws -> Household {
        guard let household = try household(id: householdID, in: context) else {
            throw NeedServiceError.householdNotFound
        }
        guard let listID else { return household }
        guard let list = try list(id: listID, in: context) else {
            throw NeedServiceError.scopeChanged
        }
        try validate(list: list, belongsTo: household)
        return household
    }

    private func validatedStoreForManagement(
        storeID: UUID,
        household: Household,
        in context: NSManagedObjectContext
    ) throws -> Store {
        guard let store = try self.store(id: storeID, in: context) else {
            throw NeedServiceError.storeNotFound
        }
        guard store.household == household,
              store.objectID.persistentStore == household.objectID.persistentStore else {
            throw NeedServiceError.scopeChanged
        }
        return store
    }

    private func storeHasReferences(_ store: Store) -> Bool {
        !(store.items?.isEmpty ?? true) || !(store.oneTimeNeeds?.isEmpty ?? true)
    }

    private func catalogItemHasReferences(_ item: Item) -> Bool {
        !(item.needs?.isEmpty ?? true)
    }

    private func validatedActiveNeed(
        needID: UUID,
        householdID: UUID,
        listID: UUID,
        in context: NSManagedObjectContext
    ) throws -> (need: Need, list: GroceryList, household: Household) {
        guard let household = try self.household(id: householdID, in: context) else {
            throw NeedServiceError.householdNotFound
        }
        guard let list = try self.list(id: listID, in: context) else {
            throw NeedServiceError.listNotFound
        }
        try validate(list: list, belongsTo: household)
        guard let need = try self.need(id: needID, in: context) else {
            throw NeedServiceError.needNotFound
        }
        guard !need.archived,
              need.list == list,
              need.objectID.persistentStore == list.objectID.persistentStore else {
            throw NeedServiceError.scopeChanged
        }
        return (need, list, household)
    }

    private func validatedOneTimeNeedInferringScope(
        needID: UUID,
        in context: NSManagedObjectContext
    ) throws -> (need: Need, list: GroceryList, household: Household) {
        guard let need = try self.need(id: needID, in: context) else {
            throw NeedServiceError.needNotFound
        }
        guard !need.archived,
              need.kind == NeedKind.oneTime.rawValue,
              need.item == nil,
              let listID = need.list?.id,
              let householdID = need.list?.household?.id else {
            throw NeedServiceError.scopeChanged
        }
        let resolved = try validatedActiveNeed(
            needID: needID,
            householdID: householdID,
            listID: listID,
            in: context
        )
        guard resolved.need === need else { throw NeedServiceError.invalidOccurrenceIdentity }
        return resolved
    }

    private func apply(_ values: RememberedNeedValues, to need: Need) throws {
        let (nextRevision, overflow) = need.revision.addingReportingOverflow(1)
        guard !overflow else { throw NeedServiceError.scopeChanged }
        need.quantity = values.quantity
        need.notes = trimmedNotes(values.purchaseNotes)
        need.urgency = values.urgency.rawValue
        need.clearOperationID = nil
        need.revision = nextRevision
    }

    private func promote(_ need: Need, to item: Item, values: RememberedNeedValues) throws {
        let (revision, overflow) = need.revision.addingReportingOverflow(1)
        guard !overflow else { throw NeedServiceError.scopeChanged }
        need.item = item
        need.kind = NeedKind.remembered.rawValue
        need.title = item.name
        need.oneTimeCategory = nil
        need.oneTimeStores = []
        need.oneTimeAnyStore = false
        need.quantity = values.quantity
        need.notes = trimmedNotes(values.purchaseNotes)
        need.urgency = values.urgency.rawValue
        need.clearOperationID = nil
        need.revision = revision
    }

    private func catalogNameCollisions(
        name: String,
        household: Household,
        excluding itemID: UUID?,
        in context: NSManagedObjectContext
    ) throws -> [UUID] {
        let request = Item.fetchRequest()
        request.predicate = NSPredicate(format: "household.id == %@", household.id as CVarArg)
        let normalized = CatalogProjection.normalizedName(name)
        let items = try context.fetch(request)
        try validateCatalogIdentities(items)
        return items
            .filter {
                $0.household == household &&
                    $0.objectID.persistentStore == household.objectID.persistentStore &&
                    $0.id != itemID &&
                    CatalogProjection.normalizedName($0.name) == normalized
            }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func validate(item: Item, belongsTo household: Household) throws {
        guard item.household == household,
              item.objectID.persistentStore == household.objectID.persistentStore else {
            throw NeedServiceError.scopeChanged
        }
    }

    private func activeStoreIDs(householdID: UUID, in context: NSManagedObjectContext) throws -> Set<UUID> {
        let request = Store.fetchRequest()
        request.predicate = NSPredicate(
            format: "household.id == %@",
            householdID as CVarArg
        )
        return Set(try validActiveStores(try context.fetch(request)).filter { !$0.isArchived }.map(\.id))
    }

    private func activeStoreIDs(household: Household, in context: NSManagedObjectContext) throws -> Set<UUID> {
        let request = Store.fetchRequest()
        request.predicate = NSPredicate(format: "household.id == %@", household.id as CVarArg)
        let stores = try validActiveStores(try context.fetch(request)).filter {
            $0.household == household &&
                $0.objectID.persistentStore == household.objectID.persistentStore
        }
        return Set(stores.filter { !$0.isArchived }.map(\.id))
    }

    private func validCatalogItems(_ items: [Item]) throws -> [Item] {
        var seen: Set<UUID> = []
        return try items.compactMap { item in
            guard item.id != PersistenceModel.unsetID else { return nil }
            guard seen.insert(item.id).inserted else { throw NeedServiceError.invalidCatalogIdentity }
            return item
        }
    }

    private func validateCatalogIdentities(_ items: [Item]) throws {
        var seen: Set<UUID> = []
        for item in items {
            guard item.id != PersistenceModel.unsetID, seen.insert(item.id).inserted else {
                throw NeedServiceError.invalidCatalogIdentity
            }
        }
    }

    private func validActiveStores(_ stores: [Store]) throws -> [Store] {
        var seen: Set<UUID> = []
        return try stores.compactMap { store in
            guard store.id != PersistenceModel.unsetID else { return nil }
            guard seen.insert(store.id).inserted else { throw NeedServiceError.invalidStoreIdentity }
            return store
        }
    }

    private func validatedName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NeedServiceError.invalidName }
        return trimmed
    }

    private func trimmedNotes(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clearOperation(id: UUID, in context: NSManagedObjectContext) throws -> ClearOperation? {
        try fetch(
            id: id,
            request: ClearOperation.fetchRequest(),
            in: context,
            identityError: .invalidClearOperationIdentity
        )
    }

    private func need(id: UUID, in context: NSManagedObjectContext) throws -> Need? {
        guard id != PersistenceModel.unsetID else { throw NeedServiceError.invalidOccurrenceIdentity }
        let request = Need.fetchRequest()
        request.fetchLimit = 2
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let matches = try context.fetch(request)
        guard matches.count < 2 else { throw NeedServiceError.invalidOccurrenceIdentity }
        return matches.first
    }

    private func fetch<T: NSManagedObject>(
        id: UUID,
        request: NSFetchRequest<T>,
        in context: NSManagedObjectContext,
        identityError: NeedServiceError = .scopeChanged
    ) throws -> T? {
        guard id != PersistenceModel.unsetID else { throw identityError }
        request.fetchLimit = 2
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let matches = try context.fetch(request)
        guard matches.count < 2 else { throw identityError }
        return matches.first
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

    private func activeRememberedNeeds(
        itemID: UUID,
        listID: UUID,
        in context: NSManagedObjectContext
    ) throws -> [Need] {
        let request = Need.fetchRequest()
        request.predicate = NSPredicate(
            format: "item.id == %@ AND list.id == %@ AND archived == NO",
            itemID as CVarArg,
            listID as CVarArg
        )
        let needs = try context.fetch(request)
        try validateOccurrenceIdentities(needs)
        return needs.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func duplicateGroup(itemID: UUID, needs: [Need]) throws -> RememberedDuplicateGroup {
        try validateOccurrenceIdentities(needs)
        let candidates = needs.map {
            RememberedDuplicateCandidate(
                needID: $0.id,
                quantity: $0.quantity,
                carted: $0.carted,
                urgency: NeedUrgency(rawValue: $0.urgency) ?? .normal,
                notes: $0.notes,
                revision: $0.revision
            )
        }.sorted { $0.needID.uuidString < $1.needID.uuidString }
        return RememberedDuplicateGroup(itemID: itemID, candidates: candidates)
    }

    private func validateOccurrenceIdentities(_ needs: [Need]) throws {
        var seen: Set<UUID> = []
        for need in needs {
            guard need.id != PersistenceModel.unsetID, seen.insert(need.id).inserted else {
                throw NeedServiceError.invalidOccurrenceIdentity
            }
        }
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
                        try self.persistence.prepareForSave(self.persistence.writer)
                        try self.persistence.writer.save()
                        if self.persistence.shareAssociationJournal != nil {
                            NotificationCenter.default.post(
                                name: PersistenceController.pendingShareAssociation,
                                object: self.persistence
                            )
                        }
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
