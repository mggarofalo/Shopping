import CoreData
import SwiftUI

enum ShoppingPreviewCase: String, CaseIterable {
    case empty
    case populated
    case longName
    case largeText
    case archivedStore
    case pendingRelationship
    case performance
    case stress
}

struct ShoppingPreviewIDs {
    let householdID: UUID
    let listID: UUID
    var storeIDs: [String: UUID] = [:]
    var categoryIDs: [String: UUID] = [:]
    var itemIDs: [String: UUID] = [:]
    var needIDs: [String: UUID] = [:]
    var clearOperationID: UUID?
}

final class ShoppingPreviewEnvironment {
    let persistence: PersistenceController
    let service: NeedService
    let ids: ShoppingPreviewIDs

    var selection: PersistenceSelection {
        PersistenceSelection(householdID: ids.householdID, listID: ids.listID)
    }

    init(persistence: PersistenceController, service: NeedService, ids: ShoppingPreviewIDs) {
        self.persistence = persistence
        self.service = service
        self.ids = ids
    }
}

enum ShoppingPreviewFixtureError: Error, Equatable {
    case storeAlreadyExists
}

enum ShoppingPreviewFixtures {
    static func make(_ fixture: ShoppingPreviewCase, storeURL: URL? = nil) throws -> ShoppingPreviewEnvironment {
        if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
            throw ShoppingPreviewFixtureError.storeAlreadyExists
        }
        let persistence = try PersistenceController(storeURL: storeURL, inMemory: storeURL == nil)
        let service = NeedService(persistence: persistence)
        let selection = try service.createHousehold(name: fixture == .longName ? longHouseholdName : "Preview household")
        var ids = ShoppingPreviewIDs(householdID: selection.householdID, listID: selection.listID)
        guard fixture != .empty else {
            return ShoppingPreviewEnvironment(persistence: persistence, service: service, ids: ids)
        }

        if fixture == .performance || fixture == .stress {
            try populateLoadFixture(
                persistence: persistence,
                itemCount: fixture == .performance ? 500 : 1_000,
                ids: &ids
            )
        } else {
            try populate(service: service, fixture: fixture, ids: &ids)
        }
        if fixture == .pendingRelationship {
            try insertPendingRelationship(in: persistence, householdID: ids.householdID, listID: ids.listID)
        }
        return ShoppingPreviewEnvironment(persistence: persistence, service: service, ids: ids)
    }

    private static func populate(
        service: NeedService,
        fixture: ShoppingPreviewCase,
        ids: inout ShoppingPreviewIDs
    ) throws {
        let householdID = ids.householdID
        let listID = ids.listID
        let costco = try service.createStore(name: "Costco", householdID: householdID, displayOrder: 0)
        let publix = try service.createStore(name: "Publix", householdID: householdID, displayOrder: 1)
        let walmart = try service.createStore(name: "Walmart", householdID: householdID, displayOrder: 2)
        let archived = try service.createStore(name: "Neighborhood Market (closed)", householdID: householdID, displayOrder: 3)
        ids.storeIDs = ["costco": costco, "publix": publix, "walmart": walmart, "archived": archived]

        let produce = try service.createCategory(name: "Produce", householdID: householdID, displayOrder: 0)
        let pantry = try service.createCategory(name: "Pantry", householdID: householdID, displayOrder: 1)
        let bakery = try service.createCategory(name: "Bakery", householdID: householdID, displayOrder: 2)
        ids.categoryIDs = ["produce": produce, "pantry": pantry, "bakery": bakery]

        let largeNotes = fixture == .largeText ? String(repeating: "Bring the reusable bags and compare the ingredient labels carefully. ", count: 18) : ""
        let bananas = try service.createItem(
            name: fixture == .longName ? longItemName : "Bananas",
            notes: largeNotes,
            categoryID: produce,
            householdID: householdID,
            anyStore: true
        )
        let granola = try service.createItem(name: "Granola", categoryID: pantry, storeIDs: [costco], householdID: householdID, anyStore: false)
        let strawberries = try service.createItem(name: "Strawberries", categoryID: produce, storeIDs: [costco], householdID: householdID, anyStore: false)
        let chipotles = try service.createItem(name: "Chipotles in adobo", categoryID: pantry, storeIDs: [publix], householdID: householdID, anyStore: false)
        let rolls = try service.createItem(name: "Dinner rolls", categoryID: bakery, storeIDs: [costco, walmart], householdID: householdID, anyStore: false)
        let needsStore = try service.createItem(name: "Local honey", categoryID: pantry, storeIDs: [archived], householdID: householdID, anyStore: false)
        try service.setStoreArchived(true, storeID: archived, householdID: householdID)
        ids.itemIDs = [
            "bananas": bananas, "granola": granola, "strawberries": strawberries,
            "chipotles": chipotles, "rolls": rolls, "needsStore": needsStore
        ]

        ids.needIDs["bananas"] = try service.addRememberedNeed(itemID: bananas, listID: listID, quantity: 6)
        ids.needIDs["granola"] = try service.addRememberedNeed(itemID: granola, listID: listID, notes: "Low sugar", urgency: .urgent)
        let strawberriesNeed = try service.addRememberedNeed(itemID: strawberries, listID: listID, quantity: 2)
        try service.setCarted(true, needID: strawberriesNeed)
        ids.needIDs["strawberries"] = strawberriesNeed
        ids.needIDs["chipotles"] = try service.addRememberedNeed(itemID: chipotles, listID: listID)
        ids.needIDs["rolls"] = try service.addRememberedNeed(itemID: rolls, listID: listID)
        ids.needIDs["needsStore"] = try service.addRememberedNeed(itemID: needsStore, listID: listID)
        ids.needIDs["oneTime"] = try service.addOneTimeNeed(
            title: "Birthday candles",
            notes: fixture == .largeText ? largeNotes : "Number candles: 4 and 0",
            categoryID: nil,
            storeIDs: [publix],
            anyStore: false,
            quantity: 1,
            urgency: .urgent,
            listID: listID
        )

        let recentlyCleared = try service.addOneTimeNeed(title: "Party ice", quantity: 3, listID: listID)
        try service.setCarted(true, needID: recentlyCleared)
        let token = try service.captureCarted(
            householdID: householdID,
            listID: listID,
            restrictedToNeedIDs: [recentlyCleared]
        )
        _ = try service.clearCarted(using: token)
        ids.needIDs["recentlyCleared"] = recentlyCleared
        ids.clearOperationID = token.id
        if fixture == .archivedStore {
            try service.setStoreArchived(true, storeID: costco, householdID: householdID)
        }
    }

    private static func insertPendingRelationship(
        in persistence: PersistenceController,
        householdID: UUID,
        listID: UUID
    ) throws {
        let context = persistence.simulationContext()
        try context.performAndWait {
            let listRequest = GroceryList.fetchRequest()
            listRequest.predicate = NSPredicate(format: "id == %@", listID as CVarArg)
            let list = try context.fetch(listRequest).first
            guard let list else { throw NeedServiceError.listNotFound }
            let need = NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as! Need
            need.id = UUID()
            need.kind = NeedKind.remembered.rawValue
            need.title = "Imported item pending"
            need.notes = "Catalog relationship has not arrived"
            need.quantity = 1
            need.carted = false
            need.urgency = NeedUrgency.normal.rawValue
            need.revision = 0
            need.archived = false
            need.oneTimeAnyStore = false
            need.list = list
            try context.save()
        }
    }

    private static func populateLoadFixture(
        persistence: PersistenceController,
        itemCount: Int,
        ids: inout ShoppingPreviewIDs
    ) throws {
        var result: Result<ShoppingPreviewIDs, Error>!
        persistence.writer.performAndWait {
            result = Result {
                let context = persistence.writer
                let householdRequest = Household.fetchRequest()
                householdRequest.predicate = NSPredicate(format: "id == %@", ids.householdID as CVarArg)
                let listRequest = GroceryList.fetchRequest()
                listRequest.predicate = NSPredicate(format: "id == %@", ids.listID as CVarArg)
                guard let household = try context.fetch(householdRequest).first else {
                    throw NeedServiceError.householdNotFound
                }
                guard let list = try context.fetch(listRequest).first else {
                    throw NeedServiceError.listNotFound
                }

                let stores: [Store] = (0..<20).map { index in
                    let store = NSEntityDescription.insertNewObject(forEntityName: "Store", into: context) as! Store
                    store.id = UUID()
                    store.name = String(format: "Store %02d", index + 1)
                    store.displayOrder = Int64(index)
                    store.isArchived = false
                    store.revision = 0
                    store.household = household
                    return store
                }
                let categories: [Category] = (0..<100).map { index in
                    let category = NSEntityDescription.insertNewObject(forEntityName: "Category", into: context) as! Category
                    category.id = UUID()
                    category.name = String(format: "Category %03d", index + 1)
                    category.displayOrder = Int64(index)
                    category.revision = 0
                    category.household = household
                    return category
                }
                var itemIDs: [String: UUID] = [:]
                var needIDs: [String: UUID] = [:]
                for index in 0..<itemCount {
                    let item = NSEntityDescription.insertNewObject(forEntityName: "Item", into: context) as! Item
                    item.id = UUID()
                    item.name = String(format: "Catalog item %04d", index + 1)
                    item.notes = index.isMultiple(of: 11) ? "Compare size and unit price" : ""
                    item.anyStore = index.isMultiple(of: 4)
                    item.isArchived = index.isMultiple(of: 97)
                    item.revision = 0
                    item.household = household
                    item.category = categories[index % categories.count]
                    if !item.anyStore {
                        item.stores = index.isMultiple(of: 7)
                            ? [stores[index % stores.count], stores[(index + 3) % stores.count]]
                            : [stores[index % stores.count]]
                    }
                    if index < 200 {
                        let need = NSEntityDescription.insertNewObject(forEntityName: "Need", into: context) as! Need
                        need.id = UUID()
                        need.kind = NeedKind.remembered.rawValue
                        need.title = item.name
                        need.notes = index.isMultiple(of: 13) ? "Load fixture note" : ""
                        need.quantity = Int64((index % 4) + 1)
                        need.carted = index.isMultiple(of: 9)
                        need.urgency = index.isMultiple(of: 10) ? NeedUrgency.urgent.rawValue : NeedUrgency.normal.rawValue
                        need.revision = 0
                        need.archived = false
                        need.clearOperationID = nil
                        need.oneTimeAnyStore = false
                        need.list = list
                        need.item = item
                        needIDs["need-\(index)"] = need.id
                    }
                    itemIDs["item-\(index)"] = item.id
                }
                try persistence.prepareForSave(context)
                try context.save()

                var updated = ids
                updated.storeIDs = Dictionary(uniqueKeysWithValues: stores.enumerated().map { ("store-\($0.offset)", $0.element.id) })
                updated.categoryIDs = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ("category-\($0.offset)", $0.element.id) })
                updated.itemIDs = itemIDs
                updated.needIDs = needIDs
                return updated
            }
        }
        ids = try result.get()
    }

    private static let longHouseholdName = "The Very Large Extended Household With an Exceptionally Descriptive Shared Grocery List Name"
    private static let longItemName = "Organic Fair Trade Extra Large Cavendish Bananas From the Family Size Produce Display"
}

struct ShoppingPreviewHost<Content: View>: View {
    private let environment: ShoppingPreviewEnvironment
    private let content: Content

    init(_ fixture: ShoppingPreviewCase = .populated, @ViewBuilder content: () -> Content) {
        environment = try! ShoppingPreviewFixtures.make(fixture)
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.managedObjectContext, environment.persistence.container.viewContext)
            .environment(\.needService, environment.service)
            .environment(\.persistenceSelection, environment.selection)
    }
}
