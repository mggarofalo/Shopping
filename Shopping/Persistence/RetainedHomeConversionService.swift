import CoreData
import Foundation

/// Copies one selected local grocery graph to a new owner-private home.
/// Legacy cart flags, cart records and clear-cart history stay with the source.
final class RetainedHomeConversionService: @unchecked Sendable {
    private let persistence: PersistenceController

    init(persistence: PersistenceController) { self.persistence = persistence }

    func capture(record: HomeAdoptionJournal.Record, session: ShopperSession) throws -> RetainedHomeConversion {
        guard record.action == .keepLocal, record.verified, record.session == session,
              let sourceURL = record.sourceURL?.standardizedFileURL.resolvingSymlinksInPath(),
              let sourceIdentifier = record.proposal.sourceStoreIdentifier,
              let householdID = record.householdID, let listID = record.listID else {
            throw RetainedHomeConversionJournal.Failure.sourceChanged
        }
        return try capture(sourceURL: sourceURL, storeIdentifier: sourceIdentifier,
            householdID: householdID, listID: listID, expectedGraph: nil,
            retainedRecordID: record.id, session: session)
    }

    func captureLocal(graph: HomeGraphIdentity, session: ShopperSession) throws -> RetainedHomeConversion {
        guard let store = persistence.store(for: .local), let sourceURL = store.url else {
            throw RetainedHomeConversionJournal.Failure.sourceChanged
        }
        return try capture(sourceURL: sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
            storeIdentifier: graph.storeIdentifier,
            householdID: graph.householdID, listID: graph.listID, expectedGraph: graph,
            retainedRecordID: nil, session: session)
    }

    private func capture(sourceURL: URL, storeIdentifier: String, householdID: UUID, listID: UUID,
                         expectedGraph: HomeGraphIdentity?, retainedRecordID: UUID?,
                         session: ShopperSession) throws -> RetainedHomeConversion {
        guard let store = persistence.store(for: .local), store.identifier == storeIdentifier,
              store.url?.standardizedFileURL.resolvingSymlinksInPath()
                == sourceURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw RetainedHomeConversionJournal.Failure.sourceChanged
        }
        var result: Result<RetainedHomeConversion, Error>!
        persistence.writer.performAndWait {
            persistence.writer.reset()
            result = Result {
                let context = persistence.writer
                let roots = try fetch(Household.self, named: "Household", id: householdID, in: context)
                let lists = try fetch(GroceryList.self, named: "GroceryList", id: listID, in: context)
                guard roots.count == 1, lists.count == 1,
                      let root = roots.first, let list = lists.first,
                      root.objectID.persistentStore == store, list.objectID.persistentStore == store,
                      root.groceryList == list, list.household == root else {
                    throw RetainedHomeConversionJournal.Failure.sourceChanged
                }
                let sourceGraph = HomeGraphIdentity(storeIdentifier: storeIdentifier,
                    rootURI: root.objectID.uriRepresentation().absoluteString,
                    householdID: root.id, listID: list.id)
                guard expectedGraph == nil || sourceGraph == expectedGraph else {
                    throw RetainedHomeConversionJournal.Failure.sourceChanged
                }
                let stores = try children(root.stores, in: store)
                let categories = try children(root.categories, in: store)
                let people = try children(root.people, in: store)
                let items = try children(root.items, in: store)
                let needs = try children(list.needs, in: store).filter { !$0.archived }
                let storeIDs = Set(stores.map(\.id))
                let categoryIDs = Set(categories.map(\.id))
                let personIDs = Set(people.map(\.id))
                let itemIDs = Set(items.map(\.id))
                for item in items {
                    guard item.household == root,
                          item.category.map({ categoryIDs.contains($0.id) }) ?? true,
                          (item.stores ?? []).allSatisfy({ storeIDs.contains($0.id) }) else {
                        throw RetainedHomeConversionJournal.Failure.sourceChanged
                    }
                }
                for need in needs {
                    guard need.list == list,
                          need.item.map({ itemIDs.contains($0.id) }) ?? true,
                          need.oneTimeCategory.map({ categoryIDs.contains($0.id) }) ?? true,
                          (need.oneTimeStores ?? []).allSatisfy({ storeIDs.contains($0.id) }),
                          need.person.map({ personIDs.contains($0.id) }) ?? true else {
                        throw RetainedHomeConversionJournal.Failure.sourceChanged
                    }
                }
                let graph = RetainedHomeConversion.Graph(householdID: UUID(), listID: UUID(), name: root.name,
                    stores: stores.map { .init(sourceID: $0.id, id: UUID(), name: $0.name,
                        order: $0.displayOrder, archived: $0.isArchived, revision: $0.revision) },
                    categories: categories.map { .init(sourceID: $0.id, id: UUID(), name: $0.name,
                        order: $0.displayOrder, archived: $0.isArchived, revision: $0.revision) },
                    people: people.map { .init(sourceID: $0.id, id: UUID(), name: $0.name,
                        order: $0.displayOrder, archived: $0.isArchived, revision: $0.revision) },
                    items: items.map { .init(sourceID: $0.id, id: UUID(), name: $0.name,
                        notes: $0.notes, anyStore: $0.anyStore, archived: $0.isArchived,
                        revision: $0.revision, categoryID: $0.category?.id,
                        storeIDs: ($0.stores ?? []).map(\.id).sorted(by: Self.uuidOrder)) },
                    needs: needs.map { .init(sourceID: $0.id, id: UUID(), kind: $0.kind,
                        title: $0.title, notes: $0.notes, quantity: $0.quantity,
                        urgency: $0.urgency, revision: $0.revision,
                        oneTimeAnyStore: $0.oneTimeAnyStore, itemID: $0.item?.id,
                        categoryID: $0.oneTimeCategory?.id,
                        storeIDs: ($0.oneTimeStores ?? []).map(\.id).sorted(by: Self.uuidOrder),
                        personID: $0.person?.id) }
                )
                return RetainedHomeConversion(id: UUID(), session: session,
                    retainedRecordID: retainedRecordID, sourceURL: sourceURL,
                    sourceStoreIdentifier: storeIdentifier, sourceGraph: sourceGraph,
                    graph: graph, targetStoreIdentifier: nil, copied: false)
            }
        }
        return try result.get()
    }

    /// A single save creates the graph. Replaying after save but before journal
    /// acknowledgement recognizes only the exact owner-private identities.
    func apply(_ command: RetainedHomeConversion) throws {
        guard let store = persistence.primaryStore,
              store.identifier == command.targetStoreIdentifier,
              (persistence.role(of: store) == .ownerPrivate
                || (!persistence.configuration.isManaged && persistence.role(of: store) == .local)),
              persistence.personalCartsEnabled,
              persistence.personalCartInitialBinding == command.session.accountBinding else {
            throw RetainedHomeConversionJournal.Failure.accountChanged
        }
        var result: Result<Void, Error>!
        persistence.writer.performAndWait {
            let context = persistence.writer
            context.reset()
            result = Result {
                guard try persistence.personalCartSessionProvider?.currentSession() == command.session else {
                    throw RetainedHomeConversionJournal.Failure.accountChanged
                }
                do {
                    let graph = command.graph
                    let existing = try fetch(Household.self, named: "Household", id: graph.householdID, in: context)
                    if !existing.isEmpty {
                        try validateCommitted(command, in: context, store: store)
                        return
                    }
                    try requireUnused(graph, in: context)
                    let root: Household = insert("Household", into: context, store: store)
                    root.id = graph.householdID
                    root.name = graph.name
                    let list: GroceryList = insert("GroceryList", into: context, store: store)
                    list.id = graph.listID
                    list.household = root
                    let stores = Dictionary(uniqueKeysWithValues: graph.stores.map { value in
                        let object: Store = insert("Store", into: context, store: store)
                        object.id = value.id
                        object.name = value.name
                        object.displayOrder = value.order
                        object.isArchived = value.archived
                        object.revision = value.revision
                        object.household = root
                        return (value.sourceID, object)
                    })
                    let categories = Dictionary(uniqueKeysWithValues: graph.categories.map { value in
                        let object: Category = insert("Category", into: context, store: store)
                        object.id = value.id
                        object.name = value.name
                        object.displayOrder = value.order
                        object.isArchived = value.archived
                        object.revision = value.revision
                        object.household = root
                        return (value.sourceID, object)
                    })
                    let people = Dictionary(uniqueKeysWithValues: graph.people.map { value in
                        let object: Person = insert("Person", into: context, store: store)
                        object.id = value.id
                        object.name = value.name
                        object.displayOrder = value.order
                        object.isArchived = value.archived
                        object.revision = value.revision
                        object.household = root
                        return (value.sourceID, object)
                    })
                    var items: [UUID: Item] = [:]
                    for value in graph.items {
                        let object: Item = insert("Item", into: context, store: store)
                        object.id = value.id
                        object.name = value.name
                        object.notes = value.notes
                        object.anyStore = value.anyStore
                        object.isArchived = value.archived
                        object.revision = value.revision
                        object.household = root
                        object.category = value.categoryID.flatMap { categories[$0] }
                        object.stores = Set(value.storeIDs.compactMap { stores[$0] })
                        items[value.sourceID] = object
                    }
                    for value in graph.needs {
                        let object: Need = insert("Need", into: context, store: store)
                        object.id = value.id
                        object.kind = value.kind
                        object.title = value.title
                        object.notes = value.notes
                        object.quantity = value.quantity
                        object.urgency = value.urgency
                        object.revision = value.revision
                        object.archived = false
                        object.carted = false
                        object.cartedAt = nil
                        object.clearOperationID = nil
                        object.oneTimeAnyStore = value.oneTimeAnyStore
                        object.list = list
                        object.item = value.itemID.flatMap { items[$0] }
                        object.oneTimeCategory = value.categoryID.flatMap { categories[$0] }
                        object.oneTimeStores = Set(value.storeIDs.compactMap { stores[$0] })
                        object.person = value.personID.flatMap { people[$0] }
                    }
                    guard try persistence.personalCartSessionProvider?.currentSession() == command.session else {
                        throw RetainedHomeConversionJournal.Failure.accountChanged
                    }
                    try persistence.prepareForSave(context)
                    try context.save()
                    if persistence.shareAssociationJournal != nil {
                        NotificationCenter.default.post(name: PersistenceController.pendingShareAssociation,
                            object: persistence)
                    }
                } catch {
                    context.rollback()
                    throw error
                }
            }
        }
        try result.get()
    }

    private func validateCommitted(_ command: RetainedHomeConversion, in context: NSManagedObjectContext,
                                   store: NSPersistentStore) throws {
        let graph = command.graph
        let root = try exactlyOne(Household.self, "Household", graph.householdID, in: context, store: store)
        let list = try exactlyOne(GroceryList.self, "GroceryList", graph.listID, in: context, store: store)
        guard root.groceryList == list, list.household == root else {
            throw RetainedHomeConversionJournal.Failure.incompleteCopy
        }
        for value in graph.stores {
            let object = try exactlyOne(Store.self, "Store", value.id, in: context, store: store)
            guard object.household == root else { throw RetainedHomeConversionJournal.Failure.incompleteCopy }
        }
        for value in graph.categories {
            let object = try exactlyOne(Category.self, "Category", value.id, in: context, store: store)
            guard object.household == root else { throw RetainedHomeConversionJournal.Failure.incompleteCopy }
        }
        for value in graph.people {
            let object = try exactlyOne(Person.self, "Person", value.id, in: context, store: store)
            guard object.household == root else { throw RetainedHomeConversionJournal.Failure.incompleteCopy }
        }
        for value in graph.items {
            let object = try exactlyOne(Item.self, "Item", value.id, in: context, store: store)
            guard object.household == root else { throw RetainedHomeConversionJournal.Failure.incompleteCopy }
        }
        for value in graph.needs {
            let object = try exactlyOne(Need.self, "Need", value.id, in: context, store: store)
            guard object.list == list else { throw RetainedHomeConversionJournal.Failure.incompleteCopy }
        }
    }

    private func requireUnused(_ graph: RetainedHomeConversion.Graph, in context: NSManagedObjectContext) throws {
        guard try fetch(GroceryList.self, named: "GroceryList", id: graph.listID, in: context).isEmpty,
              try graph.stores.allSatisfy({ try fetch(Store.self, named: "Store", id: $0.id, in: context).isEmpty }),
              try graph.categories.allSatisfy({ try fetch(Category.self, named: "Category", id: $0.id, in: context).isEmpty }),
              try graph.people.allSatisfy({ try fetch(Person.self, named: "Person", id: $0.id, in: context).isEmpty }),
              try graph.items.allSatisfy({ try fetch(Item.self, named: "Item", id: $0.id, in: context).isEmpty }),
              try graph.needs.allSatisfy({ try fetch(Need.self, named: "Need", id: $0.id, in: context).isEmpty }) else {
            throw RetainedHomeConversionJournal.Failure.incompleteCopy
        }
    }

    private func exactlyOne<T: NSManagedObject>(_ type: T.Type, _ name: String, _ id: UUID,
                                                 in context: NSManagedObjectContext,
                                                 store: NSPersistentStore) throws -> T {
        let objects = try fetch(type, named: name, id: id, in: context)
        guard objects.count == 1, let object = objects.first, object.objectID.persistentStore == store else {
            throw RetainedHomeConversionJournal.Failure.incompleteCopy
        }
        return object
    }

    private func fetch<T: NSManagedObject>(_ type: T.Type, named name: String, id: UUID,
                                           in context: NSManagedObjectContext) throws -> [T] {
        let request = NSFetchRequest<T>(entityName: name)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request)
    }

    private func children<T: IdentifiedManagedObject>(_ values: Set<T>?,
                                                      in store: NSPersistentStore) throws -> [T] {
        let values = Array(values ?? [])
        guard values.allSatisfy({ $0.id != PersistenceModel.unsetID && $0.objectID.persistentStore == store }),
              Set(values.map(\.id)).count == values.count else {
            throw RetainedHomeConversionJournal.Failure.sourceChanged
        }
        return values.sorted { Self.uuidOrder($0.id, $1.id) }
    }

    private func insert<T: NSManagedObject>(_ name: String, into context: NSManagedObjectContext,
                                            store: NSPersistentStore) -> T {
        let object = NSEntityDescription.insertNewObject(forEntityName: name, into: context) as! T
        context.assign(object, to: store)
        return object
    }

    private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool { lhs.uuidString < rhs.uuidString }
}
