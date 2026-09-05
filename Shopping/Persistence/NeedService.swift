import CoreData

struct ClearCartedToken: Codable, Equatable {
    let id: UUID
    let householdID: UUID
    let listID: UUID
    let revisionsByNeedID: [UUID: Int64]
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
    let quantity: Int64
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
            item.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            item.anyStore = anyStore
            item.isArchived = false
            self.route(item, with: household, in: context)
            item.household = household
            item.category = category
            item.stores = stores
            return item.id
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
            item.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
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
            return CatalogProjection.suggestionNames(
                from: try context.fetch(request).map { ($0.name, $0.isArchived) }
            )
        }
    }

    func allCatalogItemIDs(householdID: UUID) throws -> Set<UUID> {
        try readOnWriter { context in
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(
                format: "household.id == %@ AND isArchived == NO",
                householdID as CVarArg
            )
            return Set(try context.fetch(request).map(\.id))
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

    func filteredCatalogItemIDs(householdID: UUID, filter: CatalogItemFilter) throws -> [UUID] {
        try readOnWriter { context in
            let activeStores = try self.activeStoreIDs(householdID: householdID, in: context)
            let request = Item.fetchRequest()
            request.predicate = NSPredicate(
                format: "household.id == %@ AND isArchived == NO",
                householdID as CVarArg
            )
            return try context.fetch(request).filter { item in
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
                let value = PurchaseRuleValue(
                    explicitStoreIDs: item.map { Set($0.stores?.map(\.id) ?? []) }
                        ?? (isOneTime ? Set(need.oneTimeStores?.map(\.id) ?? []) : []),
                    anyStore: item?.anyStore ?? (isOneTime && need.oneTimeAnyStore)
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
                if let quantity { existing.quantity = quantity }
                if let notes { existing.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines) }
                existing.carted = false
                existing.urgency = urgency.rawValue
                existing.clearOperationID = nil
                existing.revision += 1
                return existing.id
            }
            guard !item.isArchived else {
                throw NeedServiceError.itemArchived
            }
            let need = self.makeNeed(title: item.name, list: list, context: context)
            need.kind = NeedKind.remembered.rawValue
            need.item = item
            need.quantity = quantity ?? 1
            need.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        quantity: Int64 = 1,
        urgency: NeedUrgency = .normal,
        listID: UUID
    ) throws -> UUID {
        let title = try validatedName(title)
        guard (1...99).contains(quantity) else { throw NeedServiceError.invalidQuantity }
        return try write { context in
            guard let list = try self.list(id: listID, in: context) else {
                throw NeedServiceError.listNotFound
            }
            guard let household = list.household else {
                throw NeedServiceError.scopeChanged
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
            need.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func setQuantity(_ quantity: Int64, needID: UUID) throws {
        guard (1...99).contains(quantity) else {
            throw NeedServiceError.invalidQuantity
        }
        try editNeed(id: needID) { $0.quantity = quantity }
    }

    func setUrgency(_ urgency: NeedUrgency, needID: UUID) throws {
        try editNeed(id: needID) { $0.urgency = urgency.rawValue }
    }

    func setPurchaseNote(_ notes: String, needID: UUID) throws {
        try editNeed(id: needID) { $0.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines) }
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
            need.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            need.oneTimeCategory = category
            need.oneTimeStores = stores
            need.oneTimeAnyStore = anyStore
            need.revision += 1
        }
    }

    func rememberOneTimeNeed(needID: UUID, existingItemID: UUID) throws -> UUID {
        try write { context in
            guard let need = try self.need(id: needID, in: context) else { throw NeedServiceError.needNotFound }
            guard !need.archived, need.kind == NeedKind.oneTime.rawValue, need.item == nil,
                  let list = need.list, let household = list.household else {
                throw NeedServiceError.scopeChanged
            }
            guard let item = try self.item(id: existingItemID, in: context) else {
                throw NeedServiceError.itemNotFound
            }
            guard !item.isArchived else { throw NeedServiceError.itemArchived }
            guard item.household == household,
                  item.objectID.persistentStore == need.objectID.persistentStore else {
                throw NeedServiceError.scopeChanged
            }
            let conflicts = try self.activeRememberedNeeds(
                itemID: existingItemID,
                listID: list.id,
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
            need.item = item
            need.kind = NeedKind.remembered.rawValue
            need.title = item.name
            need.oneTimeCategory = nil
            need.oneTimeStores = []
            need.oneTimeAnyStore = false
            need.revision += 1
            return item.id
        }
    }

    func rememberOneTimeNeedCreatingItem(needID: UUID, itemNotes: String = "") throws -> UUID {
        try write { context in
            guard let need = try self.need(id: needID, in: context) else { throw NeedServiceError.needNotFound }
            guard !need.archived, need.kind == NeedKind.oneTime.rawValue, need.item == nil,
                  let list = need.list, let household = list.household else {
                throw NeedServiceError.scopeChanged
            }
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
            item.notes = itemNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            item.anyStore = need.oneTimeAnyStore
            item.isArchived = false
            self.route(item, with: household, in: context)
            item.household = household
            item.category = category
            item.stores = stores
            need.item = item
            need.kind = NeedKind.remembered.rawValue
            need.oneTimeCategory = nil
            need.oneTimeStores = []
            need.oneTimeAnyStore = false
            need.revision += 1
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
            let captured = try context.fetch(request).filter { restrictedToNeedIDs?.contains($0.id) ?? true }
            var snapshot: [UUID: Int64] = [:]
            for need in captured {
                guard need.id != PersistenceModel.unsetID, snapshot[need.id] == nil else {
                    throw NeedServiceError.invalidOccurrenceIdentity
                }
                snapshot[need.id] = need.revision
            }
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
        need.kind = ""
        need.title = title
        need.notes = ""
        need.quantity = 1
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
        try fetch(id: id, request: Item.fetchRequest(), in: context)
    }

    private func store(id: UUID, in context: NSManagedObjectContext) throws -> Store? {
        try fetch(id: id, request: Store.fetchRequest(), in: context)
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
        guard anyStore || stores.contains(where: { !$0.isArchived }) else {
            throw NeedServiceError.scopeChanged
        }
        return Set(stores)
    }

    private func activeStoreIDs(householdID: UUID, in context: NSManagedObjectContext) throws -> Set<UUID> {
        let request = Store.fetchRequest()
        request.predicate = NSPredicate(
            format: "household.id == %@ AND isArchived == NO",
            householdID as CVarArg
        )
        return Set(try context.fetch(request).map(\.id))
    }

    private func validatedName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NeedServiceError.invalidName }
        return trimmed
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
